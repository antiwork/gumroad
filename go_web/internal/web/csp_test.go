package web

import (
	"os"
	"strings"
	"testing"
)

func productionCSP(t *testing.T, config map[string]string) CSP {
	t.Helper()
	env, err := LoadEnvironment(func(k string) string {
		return map[string]string{"RAILS_ENV": "production", "REVISION": "r"}[k]
	})
	if err != nil {
		t.Fatal(err)
	}
	csp, err := NewCSP(env, func(name, fallback string) string {
		if v, ok := config[name]; ok {
			return v
		}
		return fallback
	})
	if err != nil {
		t.Fatal(err)
	}
	return csp
}

// testdata/csp_production.txt is the header production sent with an HTML page, its nonce
// replaced.
func TestCSPMatchesProduction(t *testing.T) {
	b, err := os.ReadFile("testdata/csp_production.txt")
	if err != nil {
		t.Fatal(err)
	}
	want := strings.TrimSpace(string(b))
	if got := productionCSP(t, nil).Header("NONCE"); got != want {
		t.Errorf("CSP differs:\n got %s\nwant %s", got, want)
	}
}

func TestCSPReadsGlobalConfig(t *testing.T) {
	// A variable set to "" wins over the default, as ENV.fetch does.
	got := productionCSP(t, map[string]string{"HLS_DISTRIBUTION_URL_PROD": "", "AWS_S3_ENDPOINT": ""}).Header("")
	for _, want := range []string{"files.gumroad.com  entitlements.jwplayer.com", "blob: www.dropbox.com api.dropboxapi.com /gumroad /gumroad/ "} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in %s", want, got)
		}
	}
	if strings.Contains(got, "nonce") || strings.Contains(got, "assets.gumroad.com 'unsafe-inline'") {
		t.Errorf("a response without a nonce got one: %s", got)
	}
}

func TestCSPLeavesDevelopmentToRails(t *testing.T) {
	env, err := LoadEnvironment(func(string) string { return "" })
	if err != nil {
		t.Fatal(err)
	}
	if _, err := NewCSP(env, func(_, f string) string { return f }); err == nil {
		t.Error("development got a CSP")
	}
}

func TestMinifySourceList(t *testing.T) {
	cases := map[string]string{
		// A wildcard keeps only the other wildcard sources.
		"* data: blob: https: 'self'": "* data: blob:",
		// A host's trailing slash goes; a path's stays. uniq keeps the first.
		"https://files.gumroad.com/ example.com/ s3.amazonaws.com/b/ example.com": "files.gumroad.com example.com s3.amazonaws.com/b/",
		"wss://cable.example.com http://a.example.com 'self' 'self'":              "wss://cable.example.com a.example.com 'self'",
	}
	for in, want := range cases {
		if got := strings.Join(minifySourceList(strings.Fields(in)), " "); got != want {
			t.Errorf("%s: got %s, want %s", in, got, want)
		}
	}
}
