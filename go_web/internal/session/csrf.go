package session

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

const (
	authenticityTokenLength = 32
	// RequestForgeryProtection::GLOBAL_CSRF_TOKEN_IDENTIFIER.
	globalCSRFTokenIdentifier = "!real_csrf_token"
)

// ValidAuthenticityToken is RequestForgeryProtection#valid_authenticity_token? with
// per_form_csrf_tokens on. realToken is session[:_csrf_token]; path and method are the
// request's, which a per-form token is bound to.
func ValidAuthenticityToken(realToken, candidate, path, method string) bool {
	if realToken == "" || candidate == "" {
		return false
	}
	real, ok := rails.URLSafeDecode64(realToken)
	if !ok {
		return false
	}
	masked, ok := rails.URLSafeDecode64(candidate)
	if !ok {
		return false
	}
	switch len(masked) {
	case authenticityTokenLength:
		return fixedLengthEqual(masked, real)
	case authenticityTokenLength * 2:
		token := make([]byte, authenticityTokenLength)
		for i := range token {
			token[i] = masked[i] ^ masked[authenticityTokenLength+i]
		}
		action := strings.TrimSuffix(path, "/") + "#" + strings.ToLower(method)
		return fixedLengthEqual(token, csrfHMAC(real, globalCSRFTokenIdentifier)) ||
			fixedLengthEqual(token, real) ||
			fixedLengthEqual(token, csrfHMAC(real, action))
	}
	return false
}

func csrfHMAC(real []byte, identifier string) []byte {
	mac := hmac.New(sha256.New, real)
	mac.Write([]byte(identifier))
	return mac.Sum(nil)
}

// fixedLengthEqual is fixed_length_secure_compare, which only compares equal lengths.
func fixedLengthEqual(a, b []byte) bool {
	return len(a) == len(b) && subtle.ConstantTimeCompare(a, b) == 1
}
