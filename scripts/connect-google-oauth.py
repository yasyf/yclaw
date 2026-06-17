#!/usr/bin/env python3
# Connect a Google Workspace OAuth credential to the agent-vault `hermes` vault, headlessly.
#
# Reuses the local gws (googleworkspace-cli) desktop OAuth client (~/.config/gws/client_secret.json),
# runs a loopback consent flow (you open ONE URL in a browser on this Mac), exchanges the code for
# access+refresh tokens, and uploads them to the vault via POST /v1/credentials/oauth/tokens (the
# headless path — no vault-side callback, so the desktop client's localhost redirect is fine). The
# vault thereafter refreshes the token itself using the client id/secret + refresh token.
#
# Run on the host. Prints CONSENT_URL:<url>; open it, approve, and it finishes + verifies.
import http.server, json, os, subprocess, sys, time, urllib.parse, urllib.request

VAULT = os.environ.get("VAULT_ADDR", "http://metal.@@TAILNET_DOMAIN@@:14321")
OWNER = os.environ.get("VAULT_OWNER", "admin@hermes.local")
VAULT_NAME = "hermes"
KEY = "GOOGLE_OAUTH_TOKEN"
PORT = 8723
REDIRECT = f"http://localhost:{PORT}"
AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URL = "https://oauth2.googleapis.com/token"
SCOPES = " ".join([
    "openid",
    "https://www.googleapis.com/auth/userinfo.email",
    "https://www.googleapis.com/auth/userinfo.profile",
    "https://www.googleapis.com/auth/gmail.modify",
    "https://www.googleapis.com/auth/calendar",
    "https://www.googleapis.com/auth/drive",
    "https://www.googleapis.com/auth/spreadsheets",
    "https://www.googleapis.com/auth/documents",
    "https://www.googleapis.com/auth/presentations",
    "https://www.googleapis.com/auth/tasks",
])

def post_json(url, obj, token=None):
    h = {"Content-Type": "application/json"}
    if token:
        h["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, data=json.dumps(obj).encode(), headers=h, method="POST")
    return json.load(urllib.request.urlopen(req, timeout=30))

def get_json(url, token):
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
    return json.load(urllib.request.urlopen(req, timeout=20))

c = json.load(open(os.path.expanduser("~/.config/gws/client_secret.json")))
c = c.get("installed") or c.get("web")
CID, CSEC = c["client_id"], c["client_secret"]
MPW = subprocess.check_output(
    ["security", "find-generic-password", "-s", "yclaw-agent-vault-master", "-w"]
).decode().strip()

token = post_json(VAULT + "/v1/auth/login", {"email": OWNER, "password": MPW, "device_label": "google-oauth"})["token"]

auth = AUTH_URL + "?" + urllib.parse.urlencode({
    "client_id": CID, "redirect_uri": REDIRECT, "response_type": "code",
    "scope": SCOPES, "access_type": "offline", "prompt": "consent",
})
print("CONSENT_URL:", auth, flush=True)

holder = {}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        p = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        self.send_response(200); self.send_header("Content-Type", "text/plain"); self.end_headers()
        if "code" in p:
            holder["code"] = p["code"][0]
            self.wfile.write(b"Google connected to the vault. You can close this tab.")
        else:
            self.wfile.write(b"Waiting for the OAuth code...")
    def log_message(self, *a): pass

srv = http.server.HTTPServer(("127.0.0.1", PORT), H)
srv.timeout = 1
deadline = time.time() + 600
while "code" not in holder and time.time() < deadline:
    srv.handle_request()
if "code" not in holder:
    print("TIMEOUT waiting for consent", flush=True); sys.exit(1)

ex = urllib.parse.urlencode({
    "code": holder["code"], "client_id": CID, "client_secret": CSEC,
    "redirect_uri": REDIRECT, "grant_type": "authorization_code",
}).encode()
tr = json.load(urllib.request.urlopen(urllib.request.Request(TOKEN_URL, data=ex, method="POST"), timeout=30))
if not tr.get("refresh_token"):
    print("ERROR: no refresh_token returned (need prompt=consent + offline access)", flush=True); sys.exit(1)

resp = post_json(VAULT + "/v1/credentials/oauth/tokens", {
    "vault": VAULT_NAME, "key": KEY,
    "access_token": tr["access_token"], "refresh_token": tr["refresh_token"],
    "token_url": TOKEN_URL, "client_id": CID, "client_secret": CSEC,
    "token_auth_method": "client_secret_post",
}, token=token)
print("UPLOAD_RESULT:", json.dumps(resp), flush=True)
st = get_json(VAULT + f"/v1/credentials/oauth/status?vault={VAULT_NAME}&key={KEY}", token)
print("OAUTH_STATUS:", json.dumps(st), flush=True)
