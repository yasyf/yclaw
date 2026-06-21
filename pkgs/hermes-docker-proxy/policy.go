package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"path/filepath"
	"regexp"
	"strings"
)

// MaxCreateBody caps the create request we will buffer for screening. Real
// create bodies are a few KB; anything larger is rejected rather than streamed
// unscreened.
const MaxCreateBody = 1 << 20 // 1 MiB

// safeCaps is the exact cap-add set the agent's docker backend requests
// (tools/environments/docker.py _BASE_SECURITY_ARGS + _PRIVDROP_CAP_ARGS). Any
// CapAdd outside this set is rejected — SYS_ADMIN, NET_ADMIN, etc. never pass.
var safeCaps = map[string]bool{
	"DAC_OVERRIDE": true,
	"CHOWN":        true,
	"FOWNER":       true,
	"SETUID":       true,
	"SETGID":       true,
}

// allowedSecurityOpt is the only --security-opt the agent sets.
func allowedSecurityOpt(opt string) bool {
	switch strings.TrimSpace(opt) {
	case "no-new-privileges", "no-new-privileges:true":
		return true
	}
	return false
}

// versionPrefix strips an optional Docker API version segment ("/v1.43").
var versionPrefix = regexp.MustCompile(`^/v[0-9]+(\.[0-9]+)*`)

// route is one allowlist entry, matched against the version-stripped path.
type route struct {
	method  string
	pattern *regexp.Regexp
	inspect bool // POST /containers/create needs body screening
}

// routes is the COMPLETE set of (method, path) calls the agent's docker backend
// makes (tools/environments/docker.py: run/create/start/stop/rm, exec
// create+start+inspect, ps, inspect, image inspect, image pull, version, info,
// ping). Everything else — build, commit, cp/archive, logs, networks, volumes,
// plugins, swarm, the containerd endpoints — falls through to deny.
var routes = []route{
	{"GET", regexp.MustCompile(`^/_ping$`), false},
	{"HEAD", regexp.MustCompile(`^/_ping$`), false},
	{"GET", regexp.MustCompile(`^/version$`), false},
	{"GET", regexp.MustCompile(`^/info$`), false},
	{"GET", regexp.MustCompile(`^/containers/json$`), false},
	{"POST", regexp.MustCompile(`^/containers/create$`), true},
	{"GET", regexp.MustCompile(`^/containers/[^/]+/json$`), false},
	{"POST", regexp.MustCompile(`^/containers/[^/]+/start$`), false},
	{"POST", regexp.MustCompile(`^/containers/[^/]+/stop$`), false},
	{"POST", regexp.MustCompile(`^/containers/[^/]+/wait$`), false},
	{"POST", regexp.MustCompile(`^/containers/[^/]+/kill$`), false},
	{"DELETE", regexp.MustCompile(`^/containers/[^/]+$`), false},
	{"POST", regexp.MustCompile(`^/containers/[^/]+/exec$`), false},
	{"POST", regexp.MustCompile(`^/exec/[^/]+/start$`), false},
	{"POST", regexp.MustCompile(`^/exec/[^/]+/resize$`), false},
	{"GET", regexp.MustCompile(`^/exec/[^/]+/json$`), false},
	// Image names contain slashes (nikolaik/python-nodejs:tag), so match greedily.
	{"GET", regexp.MustCompile(`^/images/.+/json$`), false},
	{"POST", regexp.MustCompile(`^/images/create$`), false},
}

// Decision is the per-request verdict.
type Decision struct {
	Allow         bool
	Reason        string
	InspectedBody []byte // set when the body was buffered for screening; re-sent verbatim
}

func deny(reason string) Decision { return Decision{Allow: false, Reason: reason} }

// Policy screens requests against the route allowlist and create bodies against
// the host-escape rules.
type Policy struct {
	BindRoots []string
}

// Evaluate decides a single request. For POST /containers/create it consumes and
// returns the body (InspectedBody) so the caller can forward it verbatim.
func (p *Policy) Evaluate(r *http.Request) Decision {
	path := versionPrefix.ReplaceAllString(r.URL.Path, "")
	if path == "" {
		path = "/"
	}
	for _, rt := range routes {
		if rt.method != r.Method || !rt.pattern.MatchString(path) {
			continue
		}
		if !rt.inspect {
			return Decision{Allow: true}
		}
		body, err := io.ReadAll(io.LimitReader(r.Body, MaxCreateBody+1))
		if err != nil {
			return deny("could not read create body")
		}
		if len(body) > MaxCreateBody {
			return deny("create body exceeds screening limit")
		}
		if reason := p.screenCreate(body); reason != "" {
			return deny(reason)
		}
		return Decision{Allow: true, InspectedBody: body}
	}
	return deny(fmt.Sprintf("route not in allowlist: %s %s", r.Method, path))
}

// createBody is the subset of the container-create payload we screen. Unknown
// fields are ignored on decode but cannot loosen the checks below — any
// dangerous setting lives in one of these fields.
type createBody struct {
	HostConfig struct {
		Privileged     bool              `json:"Privileged"`
		Binds          []string          `json:"Binds"`
		Mounts         []mount           `json:"Mounts"`
		Devices        []json.RawMessage `json:"Devices"`
		CapAdd         []string          `json:"CapAdd"`
		Runtime        string            `json:"Runtime"`
		SecurityOpt    []string          `json:"SecurityOpt"`
		NetworkMode    string            `json:"NetworkMode"`
		PidMode        string            `json:"PidMode"`
		IpcMode        string            `json:"IpcMode"`
		UTSMode        string            `json:"UTSMode"`
		UsernsMode     string            `json:"UsernsMode"`
		CgroupnsMode   string            `json:"CgroupnsMode"`
		CgroupParent   string            `json:"CgroupParent"`
		PublishAllPorts bool             `json:"PublishAllPorts"`
	} `json:"HostConfig"`
}

type mount struct {
	Type   string `json:"Type"`
	Source string `json:"Source"`
}

// screenCreate returns "" to allow, or a reason string to deny.
func (p *Policy) screenCreate(body []byte) string {
	var c createBody
	if err := json.Unmarshal(body, &c); err != nil {
		return "create body is not valid JSON"
	}
	hc := c.HostConfig

	if hc.Privileged {
		return "HostConfig.Privileged is forbidden"
	}
	if len(hc.Devices) > 0 {
		return "HostConfig.Devices is forbidden"
	}
	if hc.Runtime != "" && hc.Runtime != "runsc" {
		return "HostConfig.Runtime override is forbidden (only runsc)"
	}
	for _, cap := range hc.CapAdd {
		norm := strings.ToUpper(strings.TrimPrefix(strings.ToUpper(strings.TrimSpace(cap)), "CAP_"))
		if !safeCaps[norm] {
			return "HostConfig.CapAdd contains a non-allowlisted capability: " + cap
		}
	}
	for _, opt := range hc.SecurityOpt {
		if !allowedSecurityOpt(opt) {
			return "HostConfig.SecurityOpt is forbidden: " + opt
		}
	}
	for _, field := range []struct{ name, val string }{
		{"NetworkMode", hc.NetworkMode},
		{"PidMode", hc.PidMode},
		{"IpcMode", hc.IpcMode},
		{"UTSMode", hc.UTSMode},
		{"UsernsMode", hc.UsernsMode},
		{"CgroupnsMode", hc.CgroupnsMode},
	} {
		if isHostNamespace(field.val) {
			return "HostConfig." + field.name + " uses a host/foreign namespace: " + field.val
		}
	}
	// Binds (the -v form): "src:dst[:opts]". src must be an absolute path under a
	// bind root; named/anonymous volumes (no abs src) are rejected.
	for _, b := range hc.Binds {
		src := b
		if i := strings.Index(b, ":"); i >= 0 {
			src = b[:i]
		}
		if ok, reason := p.bindSourceAllowed(src); !ok {
			return "HostConfig.Binds " + reason + ": " + b
		}
	}
	// Mounts (the --mount form): bind mounts get the same boundary check; tmpfs is
	// fine; named volumes are rejected (the agent never uses them).
	for _, m := range hc.Mounts {
		switch strings.ToLower(m.Type) {
		case "tmpfs":
			continue
		case "bind":
			if ok, reason := p.bindSourceAllowed(m.Source); !ok {
				return "HostConfig.Mounts bind " + reason + ": " + m.Source
			}
		case "":
			return "HostConfig.Mounts entry has no Type"
		default:
			return "HostConfig.Mounts type is forbidden: " + m.Type
		}
	}
	return ""
}

// isHostNamespace flags a *Mode value that escapes the container's own
// namespace: literal "host", or "container:<id>" (joining another container's
// namespace). Empty / "none" / "bridge" / "default" / "private" are fine.
func isHostNamespace(v string) bool {
	v = strings.ToLower(strings.TrimSpace(v))
	return v == "host" || strings.HasPrefix(v, "container:")
}

// bindSourceAllowed resolves src (following symlinks) and checks it sits within a
// configured bind root. Returns (false, reason) on rejection. NOTE: there is a
// residual TOCTOU window — the agent could repoint a symlink component between
// this check and the daemon's mount. Fully closing it requires the bind-root
// path components above the agent's writable dirs to be root-owned; see the
// module docs. EvalSymlinks requires the path to exist (it does at create time),
// which also rejects dangling symlinks.
func (p *Policy) bindSourceAllowed(src string) (bool, string) {
	src = strings.TrimSpace(src)
	if !filepath.IsAbs(src) {
		return false, "source is not an absolute path (named/anonymous volumes are forbidden)"
	}
	resolved, err := filepath.EvalSymlinks(src)
	if err != nil {
		return false, "source could not be resolved"
	}
	resolved = filepath.Clean(resolved)
	for _, root := range p.BindRoots {
		// Resolve the root through symlinks too, so a symlinked root component
		// (e.g. /tmp -> /private/tmp on macOS, or a symlinked state mount) still
		// matches the symlink-resolved source. Falls back to a clean path if the
		// root can't be resolved.
		r := filepath.Clean(root)
		if rr, err := filepath.EvalSymlinks(r); err == nil {
			r = rr
		}
		if resolved == r || strings.HasPrefix(resolved, r+string(filepath.Separator)) {
			return true, ""
		}
	}
	return false, "source is outside the allowed bind roots"
}
