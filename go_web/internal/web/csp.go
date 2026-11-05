package web

import (
	"fmt"
	"net/url"
	"slices"
	"strings"
)

// GlobalConfig is GlobalConfig.get(name, default): an environment variable that is set wins
// even when empty, then a credential that is set, then the default.
type GlobalConfig func(name, fallback string) string

// CSP is SecureHeaders' Content-Security-Policy for config/initializers/secure_headers.rb,
// built once and split where script-src's nonce goes.
type CSP struct{ beforeNonce, afterNonce string }

// cspHosts are the S3_BUCKET and ANYCABLE_HOST the initializer reads, for the environments
// whose policy has no development additions.
var cspHosts = map[string]struct{ s3Bucket, anycableHost string }{
	"production": {"gumroad", "cable.gumroad.com"},
	"staging":    {"gumroad_dev", "cable.staging.gumroad.com"},
}

// NewCSP reads the initializer's inputs as Rails does. Development's policy, which adds the
// Vite dev server, is left to Rails.
func NewCSP(e *Environment, config GlobalConfig) (CSP, error) {
	hosts, ok := cspHosts[e.Name]
	if !ok {
		return CSP{}, fmt.Errorf("no CSP for RAILS_ENV %q", e.Name)
	}
	s3Endpoint := config("AWS_S3_ENDPOINT", "https://s3.amazonaws.com")
	var hls, fileDownloads string
	if e.Name == "production" {
		hls = config("HLS_DISTRIBUTION_URL_PROD", "https://d1bdh6c3ceakz5.cloudfront.net/")
		fileDownloads = config("FILE_DOWNLOAD_DISTRIBUTION_URL_PROD", "https://files.gumroad.com/")
	} else {
		hls = config("HLS_DISTRIBUTION_URL_DEV", "https://d1jmbc8d0c0hid.cloudfront.net/")
		if s3Endpoint != "" && !strings.Contains(s3Endpoint, "amazonaws.com") {
			// USING_MINIO.
			fileDownloads = s3Endpoint + "/" + hosts.s3Bucket + "/"
		} else {
			fileDownloads = config("FILE_DOWNLOAD_DISTRIBUTION_URL_DEV", "https://staging-files.gumroad.com/")
		}
	}
	bucket, public, assetHost := hosts.s3Bucket, e.PublicStorageBucket, e.AssetHost()

	connect := []string{
		"'self'", "blob:", "www.dropbox.com", "api.dropboxapi.com",
		s3Endpoint + "/" + bucket, s3Endpoint + "/" + bucket + "/",
		s3Endpoint + "/" + public, s3Endpoint + "/" + public + "/",
		public + ".s3.amazonaws.com", public + ".s3.amazonaws.com/",
		"s3.amazonaws.com/" + public, "s3.amazonaws.com/" + public + "/",
		"www.google.com", "www.gstatic.com", "*.facebook.com", "*.facebook.net", "*.google-analytics.com",
		"*.g.doubleclick.net", "*.googletagmanager.com", "analytics.google.com", "*.analytics.google.com",
		"analytics.tiktok.com", fileDownloads, hls, "entitlements.jwplayer.com",
		"*.braintreegateway.com", "www.paypalobjects.com", "*.paypal.com", "*.braintree-api.com", "iframe.ly",
		"iframely.net", "help.gumroad.com", "unpkg.com/@lottiefiles/lottie-player@2.0.12/",
		e.Domain, "wss://" + hosts.anycableHost, assetHost,
	}
	script := []string{
		"'self'", "'unsafe-eval'", "ajax.cloudflare.com", "static.cloudflareinsights.com", "js.stripe.com",
		"api.stripe.com", "*.braintreegateway.com", "*.braintree-api.com", "www.paypalobjects.com", "*.paypal.com",
		"*.google-analytics.com", "*.googletagmanager.com", "optimize.google.com", "www.googleadservices.com",
		"www.google.com", "www.gstatic.com", "*.facebook.net", "*.facebook.com", "www.dropbox.com", "s.ytimg.com",
		"www.google.com", "cdn.iframe.ly", "platform.twitter.com", "cdn.jwplayer.com", "*.jwpcdn.com",
		"gumroad.us3.list-manage.com", "analytics.twitter.com", "analytics.tiktok.com", "help.gumroad.com",
		"unpkg.com/@lottiefiles/lottie-player@2.0.12/", e.Domain, assetHost,
	}
	// SecureHeaders' order: default-src, then the rest sorted.
	directives := []struct {
		name    string
		sources []string
	}{
		{"default-src", []string{"https:", "'self'"}},
		{"base-uri", []string{"'self'"}},
		{"child-src", []string{"'self'", "blob:"}},
		{"connect-src", connect},
		{"font-src", []string{"*", "data:", "blob:"}},
		{"frame-src", []string{"*", "data:", "blob:"}},
		{"img-src", []string{"*", "data:", "blob:"}},
		{"media-src", []string{"*", "data:", "blob:"}},
		{"object-src", []string{"'none'"}},
		{"script-src", script},
		{"style-src", []string{"'self'", "'unsafe-inline'", "s.ytimg.com", "optimize.google.com", "fonts.googleapis.com", assetHost}},
		{"worker-src", []string{"'self'", "blob:", assetHost}},
	}
	var before, after []string
	parts := &before
	for _, d := range directives {
		*parts = append(*parts, d.name+" "+strings.Join(minifySourceList(d.sources), " "))
		if d.name == "script-src" {
			parts = &after
		}
	}
	return CSP{beforeNonce: strings.Join(before, "; "), afterNonce: "; " + strings.Join(after, "; ")}, nil
}

// Header is the policy for a response. A page through the layouts always asks for a script
// nonce; one that didn't gets none.
func (c CSP) Header(scriptNonce string) string {
	if scriptNonce == "" {
		return c.beforeNonce + c.afterNonce
	}
	// append_nonce, with the 'unsafe-inline' fallback for browsers without nonces. Neither
	// changes what minifying script-src does: it has no * and no 'unsafe-inline' of its own.
	return c.beforeNonce + " 'nonce-" + scriptNonce + "' 'unsafe-inline'" + c.afterNonce
}

// cspWildcardSources is PolicyManagement::WILDCARD_SOURCES.
var cspWildcardSources = []string{"'unsafe-eval'", "'unsafe-inline'", "*", "data:", "blob:"}

// minifySourceList is ContentSecurityPolicy#minify_source_list for a list without 'none'
// beside other sources.
func minifySourceList(sources []string) []string {
	if slices.Contains(sources, "*") {
		var kept []string
		for _, s := range sources {
			if slices.Contains(cspWildcardSources, s) {
				kept = append(kept, s)
			}
		}
		return kept
	}
	out := make([]string, 0, len(sources))
	for _, s := range sources {
		// normalize_uri_paths, then strip_source_schemes.
		if u, err := url.Parse(s); err == nil && u.Path == "/" {
			s = strings.TrimSuffix(s, "/")
		} else if !strings.Contains(strings.TrimSuffix(s, "/"), "/") {
			s = strings.TrimSuffix(s, "/")
		}
		if rest, ok := strings.CutPrefix(s, "https://"); ok {
			s = rest
		} else if rest, ok := strings.CutPrefix(s, "http://"); ok {
			s = rest
		}
		if !slices.Contains(out, s) {
			out = append(out, s)
		}
	}
	return out
}
