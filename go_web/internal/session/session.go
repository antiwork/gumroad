package session

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strconv"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// CookieName is session_store.rb's key outside production.
func CookieName(railsEnv, customDomain string, branchDeployment bool) string {
	const base = "_gumroad_app_session"
	switch railsEnv {
	case "production":
		return base
	case "staging":
		if branchDeployment {
			return base + "_" + sha256Hex(customDomain)[:32]
		}
		return base + "_staging"
	default:
		return base + "_" + railsEnv
	}
}

// Session is the decoded session hash. A nil *Session reads as empty, which is also what
// a NullSessionHash looks like after a failed CSRF check.
type Session struct {
	data map[string]any
}

// Load decrypts the session cookie; a missing or unreadable cookie is an empty session.
func (c *Codec) Load(cookieName, value string, now time.Time) *Session {
	if value == "" {
		return nil
	}
	raw, ok := c.Decrypt(cookieName, value, now)
	if !ok {
		return nil
	}
	return Parse(raw)
}

// Parse reads a session hash serialized as JSON.
func Parse(raw []byte) *Session {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var data map[string]any
	if err := decoder.Decode(&data); err != nil || data == nil {
		return nil
	}
	return &Session{data: data}
}

func (s *Session) Get(key string) any {
	if s == nil {
		return nil
	}
	return s.data[key]
}

// String returns a string value, or "" when the key is missing or not a string.
func (s *Session) String(key string) string {
	v, _ := s.Get(key).(string)
	return v
}

// CSRFToken is session[:_csrf_token], the urlsafe Base64 real token.
func (s *Session) CSRFToken() (string, bool) {
	v, ok := s.Get("_csrf_token").(string)
	return v, ok
}

// WardenUser reads warden.user.user.key, which Devise writes as [[id], salt]. The salt is
// not returned: User.serialize_from_session(key, _salt) ignores it.
func (s *Session) WardenUser() (id int64, ok bool) {
	pair, isArray := s.Get("warden.user.user.key").([]any)
	if !isArray || len(pair) != 2 {
		return 0, false
	}
	key := pair[0]
	if wrapped, isArray := key.([]any); isArray {
		if len(wrapped) == 0 {
			return 0, false
		}
		key = wrapped[0]
	}
	switch k := key.(type) {
	case json.Number:
		id, err := strconv.ParseInt(string(k), 10, 64)
		return id, err == nil
	case string:
		return rails.StringToI(k)
	}
	return 0, false
}

// LastSignInAt is warden.session["last_sign_in_at"].to_i, set by devise_hooks.rb.
func (s *Session) LastSignInAt() (int64, bool) {
	scoped, _ := s.Get("warden.user.user.session").(map[string]any)
	switch v := scoped["last_sign_in_at"].(type) {
	case json.Number:
		if n, err := v.Int64(); err == nil {
			return n, true
		}
		f, err := v.Float64()
		return int64(f), err == nil
	case string:
		return rails.StringToI(v)
	}
	return 0, false
}

func sha256Hex(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}
