// hermes-docker-proxy — a default-deny filtering proxy in front of the Docker
// socket (security finding H6). The hermes agent runs untrusted input and must
// NOT be docker-group (= root-equivalent): a prompt-injected agent could
// `docker run -v /:/host` (bind mounts are honoured even under gVisor's gofer)
// to read the host's sops key + agent-vault token. This proxy is the only thing
// that owns the real socket; the agent reaches it via DOCKER_HOST and can issue
// ONLY the small set of calls its code-exec tool needs, with every
// `POST /containers/create` body screened for host-escaping HostConfig.
//
// Transport is delegated to net/http/httputil.ReverseProxy (battle-tested,
// incl. exec/attach hijacking); the only bespoke logic is the route allowlist
// and the create-body screen in policy.go, both unit-tested.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"os"
	"strconv"
	"strings"
)

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func splitRoots(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ":") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

type handler struct {
	policy *Policy
	proxy  *httputil.ReverseProxy
	logger *log.Logger
}

func (h *handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	d := h.policy.Evaluate(r)
	if !d.Allow {
		h.logger.Printf("DENY %s %s: %s", r.Method, r.URL.Path, d.Reason)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusForbidden)
		// json.Marshal so an agent-controlled bind string in the reason can't break
		// the response body. Returns the Docker-style {"message": …} shape.
		_ = json.NewEncoder(w).Encode(map[string]string{"message": "denied by hermes-docker-proxy: " + d.Reason})
		return
	}
	if d.InspectedBody != nil {
		// The policy consumed the body to screen it; hand a fresh reader to the proxy.
		r.Body = io.NopCloser(bytes.NewReader(d.InspectedBody))
		r.ContentLength = int64(len(d.InspectedBody))
		r.Header.Set("Content-Length", strconv.Itoa(len(d.InspectedBody)))
	}
	h.proxy.ServeHTTP(w, r)
}

func main() {
	listen := getenv("HERMES_DOCKER_PROXY_LISTEN", "/run/hermes-docker-proxy/docker.sock")
	upstream := getenv("HERMES_DOCKER_PROXY_UPSTREAM", "/var/run/docker.sock")
	bindRoots := splitRoots(getenv("HERMES_DOCKER_PROXY_BIND_ROOTS", "/var/lib/hermes"))
	if len(bindRoots) == 0 {
		log.Fatal("HERMES_DOCKER_PROXY_BIND_ROOTS resolved to empty — refusing to start (would allow no binds, or worse)")
	}

	policy := &Policy{BindRoots: bindRoots}

	proxy := &httputil.ReverseProxy{
		Director: func(r *http.Request) {
			r.URL.Scheme = "http"
			r.URL.Host = "docker" // dummy authority; the unix DialContext ignores it
		},
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, "unix", upstream)
			},
		},
		// Flush immediately so `docker exec` / image-pull progress streams through
		// without buffering.
		FlushInterval: -1,
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			log.Printf("upstream error %s %s: %v", r.Method, r.URL.Path, err)
			http.Error(w, "bad gateway", http.StatusBadGateway)
		},
	}

	h := &handler{policy: policy, proxy: proxy, logger: log.Default()}

	// Replace any stale socket from an unclean exit. RuntimeDirectory (systemd)
	// owns the parent dir; we own the socket node.
	_ = os.Remove(listen)
	ln, err := net.Listen("unix", listen)
	if err != nil {
		log.Fatalf("listen %s: %v", listen, err)
	}
	// Group-connectable (the agent's group); systemd sets the socket's group via
	// the service's primary Group=.
	if err := os.Chmod(listen, 0o660); err != nil {
		log.Printf("warning: chmod %s: %v", listen, err)
	}
	log.Printf("hermes-docker-proxy: %s -> %s (bind roots: %s)", listen, upstream, strings.Join(bindRoots, ","))
	srv := &http.Server{Handler: h}
	log.Fatal(srv.Serve(ln))
}
