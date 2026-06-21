package main

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRouteAllowlist(t *testing.T) {
	p := &Policy{BindRoots: []string{"/var/lib/hermes"}}
	cases := []struct {
		method, path string
		wantAllow    bool
	}{
		// Allowed — exactly what the agent's docker backend calls.
		{"GET", "/_ping", true},
		{"GET", "/v1.43/_ping", true},
		{"GET", "/version", true},
		{"GET", "/v1.50/version", true},
		{"GET", "/info", true},
		{"GET", "/containers/json", true},
		{"GET", "/v1.43/containers/json", true},
		{"GET", "/containers/abc123/json", true},
		{"POST", "/containers/abc123/start", true},
		{"POST", "/containers/abc123/stop", true},
		{"POST", "/containers/abc123/wait", true},
		{"DELETE", "/containers/abc123", true},
		{"POST", "/containers/abc123/exec", true},
		{"POST", "/exec/deadbeef/start", true},
		{"POST", "/exec/deadbeef/resize", true},
		{"GET", "/exec/deadbeef/json", true},
		{"GET", "/images/nikolaik/python-nodejs:python3.11-nodejs20/json", true},
		{"POST", "/images/create", true},
		// Denied — escape / lateral surfaces the agent never needs.
		{"POST", "/build", false},
		{"POST", "/networks/create", false},
		{"POST", "/volumes/create", false},
		{"GET", "/volumes", false},
		{"GET", "/images/json", false},
		{"GET", "/containers/abc123/logs", false},
		{"GET", "/containers/abc123/archive", false},
		{"POST", "/commit", false},
		{"POST", "/containers/abc123/update", false},
		{"GET", "/", false},
		{"POST", "/plugins/pull", false},
		// Right path, wrong method.
		{"DELETE", "/images/abc/json", false},
		{"PUT", "/containers/create", false},
	}
	for _, c := range cases {
		req := httptest.NewRequest(c.method, c.path, strings.NewReader("{}"))
		d := p.Evaluate(req)
		if d.Allow != c.wantAllow {
			t.Errorf("%s %s: allow=%v want=%v (reason=%q)", c.method, c.path, d.Allow, c.wantAllow, d.Reason)
		}
	}
}

// hostConfig builds a create body with the given HostConfig fields.
func createBodyJSON(t *testing.T, hostConfig map[string]any) string {
	t.Helper()
	b, err := json.Marshal(map[string]any{"Image": "img", "HostConfig": hostConfig})
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestScreenCreate(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "workspace"), 0o755); err != nil {
		t.Fatal(err)
	}
	// A symlink inside the root that escapes to "/", to exercise the resolve check.
	escape := filepath.Join(root, "escape")
	if err := os.Symlink("/", escape); err != nil {
		t.Fatal(err)
	}
	// An existing directory OUTSIDE the root (deterministic "outside roots" reason,
	// vs a non-existent path which fails to resolve).
	outside := t.TempDir()
	p := &Policy{BindRoots: []string{root}}

	ws := filepath.Join(root, "workspace")
	cases := []struct {
		name       string
		hostConfig map[string]any
		wantDeny   string // "" = allow; otherwise a substring the reason must contain
	}{
		{"legit workspace bind", map[string]any{
			"Binds":       []string{ws + ":/workspace"},
			"CapAdd":      []string{"DAC_OVERRIDE", "CHOWN", "FOWNER", "SETUID", "SETGID"},
			"SecurityOpt": []string{"no-new-privileges"},
		}, ""},
		{"runsc runtime ok", map[string]any{"Runtime": "runsc", "Binds": []string{ws + ":/workspace:ro"}}, ""},
		{"empty hostconfig (storage probe)", map[string]any{}, ""},
		{"tmpfs mount ok", map[string]any{"Mounts": []map[string]any{{"Type": "tmpfs", "Target": "/tmp"}}}, ""},
		{"bind root itself ok", map[string]any{"Binds": []string{root + ":/x"}}, ""},

		{"privileged", map[string]any{"Privileged": true}, "Privileged"},
		{"host root bind", map[string]any{"Binds": []string{"/:/host"}}, "outside the allowed bind roots"},
		{"existing dir outside root", map[string]any{"Binds": []string{outside + ":/s:ro"}}, "outside the allowed bind roots"},
		{"dangling source", map[string]any{"Binds": []string{"/no/such/path/xyzzy:/x"}}, "could not be resolved"},
		{"runc override", map[string]any{"Runtime": "runc"}, "Runtime override"},
		{"bad capadd", map[string]any{"CapAdd": []string{"SYS_ADMIN"}}, "non-allowlisted capability"},
		{"bad capadd cap_ prefix", map[string]any{"CapAdd": []string{"CAP_NET_ADMIN"}}, "non-allowlisted capability"},
		{"device", map[string]any{"Devices": []map[string]any{{"PathOnHost": "/dev/kmsg"}}}, "Devices"},
		{"network host", map[string]any{"NetworkMode": "host"}, "host/foreign namespace"},
		{"pid host", map[string]any{"PidMode": "host"}, "host/foreign namespace"},
		{"pid container", map[string]any{"PidMode": "container:other"}, "host/foreign namespace"},
		{"ipc host", map[string]any{"IpcMode": "host"}, "host/foreign namespace"},
		{"userns host", map[string]any{"UsernsMode": "host"}, "host/foreign namespace"},
		{"seccomp unconfined", map[string]any{"SecurityOpt": []string{"seccomp=unconfined"}}, "SecurityOpt is forbidden"},
		{"apparmor unconfined", map[string]any{"SecurityOpt": []string{"apparmor=unconfined"}}, "SecurityOpt is forbidden"},
		{"label disable", map[string]any{"SecurityOpt": []string{"label:disable"}}, "SecurityOpt is forbidden"},
		{"mount bind escape", map[string]any{"Mounts": []map[string]any{{"Type": "bind", "Source": outside}}}, "outside the allowed bind roots"},
		{"mount volume", map[string]any{"Mounts": []map[string]any{{"Type": "volume", "Source": "v"}}}, "Mounts type is forbidden"},
		{"named volume bind", map[string]any{"Binds": []string{"myvol:/data"}}, "not an absolute path"},
		{"symlink escape", map[string]any{"Binds": []string{escape + ":/x"}}, "outside the allowed bind roots"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			reason := p.screenCreate([]byte(createBodyJSON(t, c.hostConfig)))
			if c.wantDeny == "" {
				if reason != "" {
					t.Errorf("expected allow, got deny: %s", reason)
				}
				return
			}
			if !strings.Contains(reason, c.wantDeny) {
				t.Errorf("deny reason = %q, want substring %q", reason, c.wantDeny)
			}
		})
	}
}

func TestScreenCreateInvalidJSON(t *testing.T) {
	p := &Policy{BindRoots: []string{"/var/lib/hermes"}}
	if r := p.screenCreate([]byte("{not json")); r == "" {
		t.Error("expected deny on invalid JSON")
	}
}

// The create route must screen the body end-to-end via Evaluate and return it
// for verbatim forwarding.
func TestEvaluateCreateRoundTrip(t *testing.T) {
	root := t.TempDir()
	p := &Policy{BindRoots: []string{root}}
	body := createBodyJSON(t, map[string]any{"Binds": []string{root + ":/x"}})
	req := httptest.NewRequest("POST", "/v1.43/containers/create", strings.NewReader(body))
	d := p.Evaluate(req)
	if !d.Allow {
		t.Fatalf("expected allow, got %s", d.Reason)
	}
	if string(d.InspectedBody) != body {
		t.Errorf("InspectedBody not preserved:\n got %q\nwant %q", d.InspectedBody, body)
	}

	bad := createBodyJSON(t, map[string]any{"Binds": []string{"/:/host"}})
	req2 := httptest.NewRequest("POST", "/containers/create", strings.NewReader(bad))
	if d2 := p.Evaluate(req2); d2.Allow {
		t.Error("expected deny for host-root bind via Evaluate")
	}
}
