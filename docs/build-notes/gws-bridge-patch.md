# Build Note: `gws_bridge.py` Patch (agent-vault interception)

## Goal

Make the Google Workspace bridge stop doing local OAuth token refresh. Instead it should
hand `gws` a **dummy** bearer token and rely on **agent-vault** (a forward proxy reached via
`HTTPS_PROXY`) to rewrite the `Authorization` header on the wire for requests to
`*.googleapis.com`. The later agent will turn the BEFORE/AFTER below into a unified diff at
`scripts/gws-bridge.patch`.

## Source of truth

- File to patch: `/tmp/hermes-agent-ref/skills/productivity/google-workspace/scripts/gws_bridge.py` (read in full, 112 lines).
- Supporting: `_hermes_home.py` (provides `get_hermes_home()`), `google_api.py` (a *separate*
  `gws` caller — see §6, NOT in scope for this patch).

### Path for the unified diff header

The repo layout under the skill places this script at:

```
skills/productivity/google-workspace/scripts/gws_bridge.py
```

So the diff header lines must read (git-style, `a/`…`b/` prefixes):

```
--- a/skills/productivity/google-workspace/scripts/gws_bridge.py
+++ b/skills/productivity/google-workspace/scripts/gws_bridge.py
```

TODO(human): Confirm the patch base dir. The reference copy lives under
`/tmp/hermes-agent-ref/`. The Nix build must apply this patch against whatever path the
skill is vendored to in the Hermes repo. If the build applies with `-p1` from the skill root,
the header above is correct; if applied from a different root, adjust the `a/`…`b/` prefix
or pass the matching `-p` level.

---

## 1. How the bridge currently obtains the token + sets `GOOGLE_WORKSPACE_CLI_TOKEN`

Two pieces:

**(a) Token comes from `~/.hermes/google_token.json`** via `get_token_path()` →
`get_hermes_home() / "google_token.json"`. `get_hermes_home()` resolves `HERMES_HOME`
(default `~/.hermes`) — `_hermes_home.py:31-32`.

**(b) `main()` reads a valid token then injects it into the child env** — `gws_bridge.py:96-107`:

```python
def main():
    """Refresh token if needed, then exec gws with remaining args."""
    if len(sys.argv) < 2:
        print("Usage: gws_bridge.py <gws args...>", file=sys.stderr)
        sys.exit(1)

    access_token = get_valid_token()          # line 102 — local refresh path
    env = os.environ.copy()
    env["GOOGLE_WORKSPACE_CLI_TOKEN"] = access_token   # line 104 — real bearer injected
    result = subprocess.run(["gws"] + sys.argv[1:], env=env)
    sys.exit(result.returncode)
```

So today the **real** Google access token is placed in `GOOGLE_WORKSPACE_CLI_TOKEN`, and `gws`
sends it as the `Authorization: Bearer <token>` header to `*.googleapis.com`.

---

## 2. Local refresh logic that must be DELETED

The entire local token-fetch machinery. Three functions plus their imports:

**`refresh_token()` — `gws_bridge.py:32-74`** (reads `client_id`/`client_secret`/`refresh_token`/`token_uri`
from the JSON, POSTs to Google's token endpoint via `urllib`, caches `access_token` back to disk):

```python
def refresh_token(token_data: dict) -> dict:
    """Refresh the access token using the refresh token."""
    import urllib.error
    import urllib.parse
    import urllib.request

    required_keys = ["client_id", "client_secret", "refresh_token", "token_uri"]
    missing = [k for k in required_keys if k not in token_data]
    if missing:
        print(f"ERROR: google_token.json is missing required fields: {', '.join(missing)}", file=sys.stderr)
        print("Please re-authenticate by running the Google Workspace setup script.", file=sys.stderr)
        sys.exit(1)

    params = urllib.parse.urlencode({
        "client_id": token_data["client_id"],
        "client_secret": token_data["client_secret"],
        "refresh_token": token_data["refresh_token"],
        "grant_type": "refresh_token",
    }).encode()

    req = urllib.request.Request(token_data["token_uri"], data=params)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            result = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        print(f"ERROR: Token refresh failed (HTTP {e.code}): {body}", file=sys.stderr)
        print("Re-run setup.py to re-authenticate.", file=sys.stderr)
        sys.exit(1)
    except (urllib.error.URLError, TimeoutError) as e:
        print(f"ERROR: Token refresh failed (network): {e}", file=sys.stderr)
        sys.exit(1)

    token_data["token"] = result["access_token"]
    token_data["expiry"] = datetime.fromtimestamp(
        datetime.now(timezone.utc).timestamp() + result["expires_in"],
        tz=timezone.utc,
    ).isoformat()

    get_token_path().write_text(
        json.dumps(_normalize_authorized_user_payload(token_data), indent=2)
    )
    return token_data
```

**`get_valid_token()` — `gws_bridge.py:77-93`** (loads the JSON, checks `expiry`, calls
`refresh_token` when stale, returns `token_data["token"]`):

```python
def get_valid_token() -> str:
    """Return a valid access token, refreshing if needed."""
    token_path = get_token_path()
    if not token_path.exists():
        print("ERROR: No Google token found. Run setup.py --auth-url first.", file=sys.stderr)
        sys.exit(1)

    token_data = json.loads(token_path.read_text())

    expiry = token_data.get("expiry", "")
    if expiry:
        exp_dt = datetime.fromisoformat(expiry.replace("Z", "+00:00"))
        now = datetime.now(timezone.utc)
        if now >= exp_dt:
            token_data = refresh_token(token_data)

    return token_data["token"]
```

Also delete the now-unused helpers/imports these depend on:
- `get_token_path()` — `gws_bridge.py:21-22`
- `_normalize_authorized_user_payload()` — `gws_bridge.py:25-29`
- module imports made dead by the deletion: `json` (line 6), `datetime`/`timezone` (line 10),
  `Path` (line 11) is still used by the `_SCRIPTS_DIR` sys.path shim (lines 13-16), so KEEP `from pathlib import Path`.
- The `from _hermes_home import get_hermes_home` import (line 18) becomes dead once `get_token_path()`
  is removed — delete it. The sys.path shim at lines 13-16 was only there so that import would
  resolve; with the import gone, lines 13-16 can also be removed.

> NOTE: after deletion, `os`, `subprocess`, `sys` are the only stdlib imports still used.
> `json`, `datetime`, `timezone`, `Path`, and `get_hermes_home` all go away.

---

## 3. How `gws` is invoked + proxy passthrough

**Invocation — `gws_bridge.py:106`:**

```python
result = subprocess.run(["gws"] + sys.argv[1:], env=env)
```

- argv: literal `"gws"` (resolved via the child's `PATH`) followed by every arg passed to the
  bridge (`sys.argv[1:]`). No `capture_output` — stdout/stderr inherit the parent's.
- env dict: `env = os.environ.copy()` (line 103) **plus** `GOOGLE_WORKSPACE_CLI_TOKEN` (line 104).

**Proxy passthrough — already works, no extra code needed.** Because `env` is a full copy of
`os.environ`, any `HTTPS_PROXY` / `HTTP_PROXY` / `NO_PROXY` already present in the bridge's
environment is inherited by the `gws` child automatically. There is **no** code that strips,
overrides, or filters proxy vars. So agent-vault's proxy address reaches `gws` as long as it is
exported in the environment that launches `gws_bridge.py`.

TODO(human): Confirm the `gws` binary honors `HTTPS_PROXY`/`HTTP_PROXY` for its outbound HTTPS
calls to `*.googleapis.com`. The bridge passes the vars through, but whether `gws` (likely a Go
binary) reads them is a property of `gws` itself — verify against the `gws` build, or set
the canonical env var name `gws` expects. (Go's `net/http` `ProxyFromEnvironment` reads
`HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY`, lower- and upper-case, so this is likely fine.)

BLOCKER: For agent-vault to overwrite the bearer on the wire it must MITM TLS to
`*.googleapis.com`, which means `gws` must trust agent-vault's CA. The bridge sets no
`SSL_CERT_FILE` / `NODE_EXTRA_CA_CERTS` / `GODEBUG` and does nothing about CA trust. Decide
where the CA bundle is injected (system trust store at the Nix/OS layer, or an env var the
`gws` binary honors). This patch does not address it.

---

## 4. Minimal change — BEFORE / AFTER

The patch reduces the file to: keep the shebang/docstring (reword), keep `os`/`subprocess`/`sys`
imports, add the dummy-token constant, and reduce `main()` to set the dummy token and exec `gws`.

### Dummy token constant

Use `"__google_oauth__"` as the sentinel agent-vault keys on. Per STYLEGUIDE "Code Organization"
(constants immediately after imports), declare it as a module constant.

### BEFORE (entire file, `gws_bridge.py:1-112`)

```python
#!/usr/bin/env python3
"""Bridge between Hermes OAuth token and gws CLI.

Refreshes the token if expired, then executes gws with the valid access token.
"""
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

# Ensure sibling modules (_hermes_home) are importable when run standalone.
_SCRIPTS_DIR = str(Path(__file__).resolve().parent)
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

from _hermes_home import get_hermes_home


def get_token_path() -> Path:
    return get_hermes_home() / "google_token.json"


def _normalize_authorized_user_payload(payload: dict) -> dict:
    normalized = dict(payload)
    if not normalized.get("type"):
        normalized["type"] = "authorized_user"
    return normalized


def refresh_token(token_data: dict) -> dict:
    """Refresh the access token using the refresh token."""
    import urllib.error
    import urllib.parse
    import urllib.request

    required_keys = ["client_id", "client_secret", "refresh_token", "token_uri"]
    missing = [k for k in required_keys if k not in token_data]
    if missing:
        print(f"ERROR: google_token.json is missing required fields: {', '.join(missing)}", file=sys.stderr)
        print("Please re-authenticate by running the Google Workspace setup script.", file=sys.stderr)
        sys.exit(1)

    params = urllib.parse.urlencode({
        "client_id": token_data["client_id"],
        "client_secret": token_data["client_secret"],
        "refresh_token": token_data["refresh_token"],
        "grant_type": "refresh_token",
    }).encode()

    req = urllib.request.Request(token_data["token_uri"], data=params)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            result = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        print(f"ERROR: Token refresh failed (HTTP {e.code}): {body}", file=sys.stderr)
        print("Re-run setup.py to re-authenticate.", file=sys.stderr)
        sys.exit(1)
    except (urllib.error.URLError, TimeoutError) as e:
        print(f"ERROR: Token refresh failed (network): {e}", file=sys.stderr)
        sys.exit(1)

    token_data["token"] = result["access_token"]
    token_data["expiry"] = datetime.fromtimestamp(
        datetime.now(timezone.utc).timestamp() + result["expires_in"],
        tz=timezone.utc,
    ).isoformat()

    get_token_path().write_text(
        json.dumps(_normalize_authorized_user_payload(token_data), indent=2)
    )
    return token_data


def get_valid_token() -> str:
    """Return a valid access token, refreshing if needed."""
    token_path = get_token_path()
    if not token_path.exists():
        print("ERROR: No Google token found. Run setup.py --auth-url first.", file=sys.stderr)
        sys.exit(1)

    token_data = json.loads(token_path.read_text())

    expiry = token_data.get("expiry", "")
    if expiry:
        exp_dt = datetime.fromisoformat(expiry.replace("Z", "+00:00"))
        now = datetime.now(timezone.utc)
        if now >= exp_dt:
            token_data = refresh_token(token_data)

    return token_data["token"]


def main():
    """Refresh token if needed, then exec gws with remaining args."""
    if len(sys.argv) < 2:
        print("Usage: gws_bridge.py <gws args...>", file=sys.stderr)
        sys.exit(1)

    access_token = get_valid_token()
    env = os.environ.copy()
    env["GOOGLE_WORKSPACE_CLI_TOKEN"] = access_token

    result = subprocess.run(["gws"] + sys.argv[1:], env=env)
    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
```

### AFTER (entire file)

```python
#!/usr/bin/env python3
"""Bridge between Hermes and the gws CLI.

Sets a dummy bearer token and execs gws. The real Authorization header for
*.googleapis.com is rewritten on the wire by agent-vault (reached via the
proxy env vars inherited from this process), so no local OAuth refresh happens
here.
"""
import os
import subprocess
import sys

DUMMY_TOKEN = "__google_oauth__"


def main():
    """Exec gws with a dummy token; agent-vault rewrites the bearer on the wire."""
    if len(sys.argv) < 2:
        print("Usage: gws_bridge.py <gws args...>", file=sys.stderr)
        sys.exit(1)

    env = os.environ.copy()
    env["GOOGLE_WORKSPACE_CLI_TOKEN"] = DUMMY_TOKEN

    result = subprocess.run(["gws"] + sys.argv[1:], env=env)
    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
```

### What changed, mapped to the requirements

| Req | Change |
| --- | --- |
| (a) dummy token | Add `DUMMY_TOKEN = "__google_oauth__"`; `env["GOOGLE_WORKSPACE_CLI_TOKEN"] = DUMMY_TOKEN` |
| (b) remove refresh/token-fetch | Delete `refresh_token` (32-74), `get_valid_token` (77-93), `get_token_path` (21-22), `_normalize_authorized_user_payload` (25-29), and the `_hermes_home` import + sys.path shim (13-18); drop `access_token = get_valid_token()` |
| (c) ensure `HTTPS_PROXY` reaches `gws` | No code change required — `env = os.environ.copy()` already inherits `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY`. Preserved verbatim. |

---

## 5. The token file (`~/.hermes/google_token.json`) — what stays

The bridge no longer reads it. But `google_api.py` (the Python fallback / separate `gws` caller)
still uses it (§6), and `setup.py` still writes it. So `google_token.json` is NOT removed by this
patch — only the bridge's *dependency* on it is.

## 6. Out of scope (do NOT touch in this patch)

`google_api.py` is a **separate** `gws` invoker with its own auth model:
- `_gws_env()` — `google_api.py:89-92` — sets `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE = TOKEN_PATH`
  (a *file path*, not a bearer), and copies `os.environ` (so proxies pass through there too).
- `_run_gws()` — `google_api.py:95-128` — runs `gws` with `capture_output=True`, expecting JSON.
- `get_credentials()` — `google_api.py:181-200` — uses `google.oauth2` to refresh on disk.

This patch is scoped to `gws_bridge.py` only. If the architecture later wants `google_api.py`
to also defer to agent-vault, that is a separate change.

TODO(human): Decide whether `google_api.py` (which points `gws` at the credentials *file* via
`GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE`, and separately refreshes via the Python google-auth lib)
should likewise be cut over to the dummy-token + proxy model, or left as-is. The two callers will
otherwise behave differently (bridge = dummy token + agent-vault; api = real on-disk creds).

---

## 7. Verification

After the later agent produces `scripts/gws-bridge.patch` and applies it:

1. Syntax/import sanity:
   `python3 -c "import ast,sys; ast.parse(open('skills/productivity/google-workspace/scripts/gws_bridge.py').read())"`
2. No dead imports / no leftover refresh code:
   `rg -n "refresh_token|google_token|urllib|get_valid_token|_hermes_home|GOOGLE_WORKSPACE_CLI_TOKEN" skills/productivity/google-workspace/scripts/gws_bridge.py`
   — should match only the single `GOOGLE_WORKSPACE_CLI_TOKEN` assignment.
3. Dummy token reaches `gws` and proxy passes through. Stub `gws` on PATH to dump its env:
   ```
   printf '#!/usr/bin/env bash\nenv | grep -E "GOOGLE_WORKSPACE_CLI_TOKEN|HTTPS_PROXY"\n' > /tmp/gws && chmod +x /tmp/gws
   PATH=/tmp:$PATH HTTPS_PROXY=http://agent-vault:8080 python3 .../gws_bridge.py gmail messages list
   ```
   Expect output containing `GOOGLE_WORKSPACE_CLI_TOKEN=__google_oauth__` and
   `HTTPS_PROXY=http://agent-vault:8080`.
4. End-to-end (real): with agent-vault running and trusting Google MITM, run a real
   `gws_bridge.py gmail ...` and confirm a 200 (agent-vault swapped the bearer).
