package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func testPolicy() policy {
	return policy{
		blockedDomains:       normalizedSet("skynexyl.com"),
		blockedRequestedWith: normalizedSet("com.skynex.app"),
	}
}

func TestBlockReason(t *testing.T) {
	p := testPolicy()
	tests := []struct {
		name    string
		headers map[string]string
		blocked bool
	}{
		{name: "requested with", headers: map[string]string{"X-Requested-With": "com.skynex.app"}, blocked: true},
		{name: "requested with case insensitive", headers: map[string]string{"X-Requested-With": "COM.SKYNEX.APP"}, blocked: true},
		{name: "origin exact domain", headers: map[string]string{"Origin": "https://skynexyl.com"}, blocked: true},
		{name: "origin subdomain", headers: map[string]string{"Origin": "https://api.skynexyl.com:8443"}, blocked: true},
		{name: "referer path", headers: map[string]string{"Referer": "https://www.skynexyl.com/chat?id=1"}, blocked: true},
		{name: "lookalike domain allowed", headers: map[string]string{"Origin": "https://skynexyl.com.example.org"}, blocked: false},
		{name: "unrelated webview allowed", headers: map[string]string{"X-Requested-With": "com.example.app", "Origin": "https://example.com"}, blocked: false},
		{name: "missing headers allowed", headers: nil, blocked: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
			for key, value := range tt.headers {
				req.Header.Set(key, value)
			}
			got := p.blockReason(req) != ""
			if got != tt.blocked {
				t.Fatalf("blocked = %t, want %t; reason=%q", got, tt.blocked, p.blockReason(req))
			}
		})
	}
}

func TestPrepareCPAConfigPreservesOtherSettings(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.yaml")
	original := "host: \"\"\nport: 8080\napi-keys:\n  - secret\nremote-management:\n  allow-remote: true\n"
	if errWrite := os.WriteFile(path, []byte(original), 0o644); errWrite != nil {
		t.Fatal(errWrite)
	}
	if errPrepare := prepareCPAConfig(path, 8317); errPrepare != nil {
		t.Fatal(errPrepare)
	}
	data, errRead := os.ReadFile(path)
	if errRead != nil {
		t.Fatal(errRead)
	}
	text := string(data)
	for _, want := range []string{`host: "127.0.0.1"`, "port: 8317", "api-keys:\n  - secret", "remote-management:\n  allow-remote: true"} {
		if !strings.Contains(text, want) {
			t.Fatalf("prepared config missing %q:\n%s", want, text)
		}
	}
	info, errStat := os.Stat(path)
	if errStat != nil {
		t.Fatal(errStat)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("config mode = %o, want 600", info.Mode().Perm())
	}
}

func TestPrepareCPAConfigAddsMissingListenerKeys(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.yaml")
	if errWrite := os.WriteFile(path, []byte("debug: false\n"), 0o600); errWrite != nil {
		t.Fatal(errWrite)
	}
	if errPrepare := prepareCPAConfig(path, 9000); errPrepare != nil {
		t.Fatal(errPrepare)
	}
	data, _ := os.ReadFile(path)
	text := string(data)
	if !strings.Contains(text, `host: "127.0.0.1"`) || !strings.Contains(text, "port: 9000") {
		t.Fatalf("listener keys missing:\n%s", text)
	}
}

func TestHeaderHost(t *testing.T) {
	for raw, want := range map[string]string{
		"https://www.skynexyl.com/path": "www.skynexyl.com",
		"https://SKYNEXYL.COM:443":      "skynexyl.com",
		"null":                          "",
		"":                              "",
	} {
		if got := headerHost(raw); got != want {
			t.Fatalf("headerHost(%q) = %q, want %q", raw, got, want)
		}
	}
}
