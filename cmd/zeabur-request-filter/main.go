// Command zeabur-request-filter is a small reverse proxy placed in front of
// CLIProxyAPI for the private Zeabur deployment. It rejects known abusive web
// clients before their requests reach CPA or an upstream model.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type policy struct {
	blockedDomains       map[string]struct{}
	blockedRequestedWith map[string]struct{}
}

func main() {
	listen := flag.String("listen", ":8080", "public listen address")
	upstream := flag.String("upstream", "http://127.0.0.1:8317", "CLIProxyAPI upstream URL")
	blockedDomains := flag.String("blocked-domains", "skynexyl.com", "comma-separated Origin/Referer domains to reject")
	blockedRequestedWith := flag.String("blocked-requested-with", "com.skynex.app", "comma-separated X-Requested-With values to reject")
	prepareConfig := flag.String("prepare-config", "", "rewrite top-level CPA host and port in this config, then exit")
	internalPort := flag.Int("internal-port", 8317, "internal CPA port used with -prepare-config")
	flag.Parse()

	if *prepareConfig != "" {
		if errPrepare := prepareCPAConfig(*prepareConfig, *internalPort); errPrepare != nil {
			log.Fatal(errPrepare)
		}
		return
	}

	target, err := url.Parse(*upstream)
	if err != nil || target.Scheme == "" || target.Host == "" {
		log.Fatalf("invalid upstream URL %q: %v", *upstream, err)
	}

	p := policy{
		blockedDomains:       normalizedSet(*blockedDomains),
		blockedRequestedWith: normalizedSet(*blockedRequestedWith),
	}
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, proxyErr error) {
		log.Printf("proxy error for %s %s: %v", r.Method, r.URL.RequestURI(), proxyErr)
		writeJSONError(w, http.StatusBadGateway, "upstream proxy unavailable")
	}

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if reason := p.blockReason(r); reason != "" {
			log.Printf("blocked request: reason=%s method=%s path=%s remote=%s", reason, r.Method, r.URL.Path, r.RemoteAddr)
			if reason == "nextjs-probe" {
				http.NotFound(w, r)
				return
			}
			writeJSONError(w, http.StatusForbidden, "request blocked by gateway policy")
			return
		}
		proxy.ServeHTTP(w, r)
	})

	server := &http.Server{
		Addr:              *listen,
		Handler:           handler,
		ReadHeaderTimeout: 15 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
	log.Printf("request filter listening on %s and proxying to %s", *listen, target.String())
	if errServe := server.ListenAndServe(); !errors.Is(errServe, http.ErrServerClosed) {
		log.Fatal(errServe)
	}
}

func prepareCPAConfig(path string, port int) error {
	if port < 1 || port > 65535 {
		return fmt.Errorf("internal port %d is outside 1..65535", port)
	}
	data, errRead := os.ReadFile(path)
	if errRead != nil {
		return fmt.Errorf("read CPA config: %w", errRead)
	}
	lines := strings.Split(strings.ReplaceAll(string(data), "\r\n", "\n"), "\n")
	hostSeen := false
	portSeen := false
	for index, line := range lines {
		if strings.HasPrefix(line, "host:") {
			lines[index] = `host: "127.0.0.1"`
			hostSeen = true
			continue
		}
		if strings.HasPrefix(line, "port:") {
			lines[index] = fmt.Sprintf("port: %d", port)
			portSeen = true
		}
	}
	if !hostSeen {
		lines = append(lines, `host: "127.0.0.1"`)
	}
	if !portSeen {
		lines = append(lines, fmt.Sprintf("port: %d", port))
	}
	output := strings.Join(lines, "\n")
	if !strings.HasSuffix(output, "\n") {
		output += "\n"
	}

	dir := filepath.Dir(path)
	temp, errCreate := os.CreateTemp(dir, ".cpa-listener-*.yaml")
	if errCreate != nil {
		return fmt.Errorf("create temporary CPA config: %w", errCreate)
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)
	if errChmod := temp.Chmod(0o600); errChmod != nil {
		_ = temp.Close()
		return fmt.Errorf("secure temporary CPA config: %w", errChmod)
	}
	if _, errWrite := temp.WriteString(output); errWrite != nil {
		_ = temp.Close()
		return fmt.Errorf("write temporary CPA config: %w", errWrite)
	}
	if errClose := temp.Close(); errClose != nil {
		return fmt.Errorf("close temporary CPA config: %w", errClose)
	}
	if errRename := os.Rename(tempPath, path); errRename != nil {
		return fmt.Errorf("replace CPA config: %w", errRename)
	}
	return nil
}

func (p policy) blockReason(r *http.Request) string {
	if r == nil {
		return "invalid-request"
	}
	if r.Method == http.MethodPost && r.URL != nil && r.URL.Path == "/" &&
		(r.Header.Get("Next-Action") != "" || r.Header.Get("X-Nextjs-Request-Id") != "") {
		return "nextjs-probe"
	}
	requestedWith := strings.ToLower(strings.TrimSpace(r.Header.Get("X-Requested-With")))
	if _, blocked := p.blockedRequestedWith[requestedWith]; blocked && requestedWith != "" {
		return "x-requested-with:" + requestedWith
	}
	for _, headerName := range []string{"Origin", "Referer"} {
		if host := headerHost(r.Header.Get(headerName)); host != "" && domainBlocked(host, p.blockedDomains) {
			return strings.ToLower(headerName) + ":" + host
		}
	}
	return ""
}

func headerHost(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" || strings.EqualFold(raw, "null") {
		return ""
	}
	parsed, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	return strings.ToLower(strings.TrimSuffix(parsed.Hostname(), "."))
}

func domainBlocked(host string, blockedDomains map[string]struct{}) bool {
	host = strings.ToLower(strings.TrimSuffix(strings.TrimSpace(host), "."))
	for domain := range blockedDomains {
		if host == domain || strings.HasSuffix(host, "."+domain) {
			return true
		}
	}
	return false
}

func normalizedSet(raw string) map[string]struct{} {
	out := make(map[string]struct{})
	for _, item := range strings.Split(raw, ",") {
		item = strings.ToLower(strings.TrimSuffix(strings.TrimSpace(item), "."))
		if item != "" {
			out[item] = struct{}{}
		}
	}
	return out
}

func writeJSONError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"error": map[string]string{
			"type":    "request_blocked",
			"message": message,
		},
	})
}
