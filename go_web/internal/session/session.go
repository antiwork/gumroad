package session

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strconv"
	"strings"
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

// Session is the decoded session hash, in Ruby's key order so a rewrite keeps it. A nil
// *Session reads as empty, which is also what a NullSessionHash looks like after a failed
// CSRF check.
type Session struct {
	data *rails.Hash
}

const sessionIDKey = "session_id"

// New is the session Rack's cookie store starts for a request without one:
// persistent_session_id! gives it a session_id first.
func New() *Session {
	s := &Session{data: rails.NewHash()}
	s.data.Set(sessionIDKey, newSessionID())
	return s
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

// Parse reads a session hash serialized as JSON. A session without a session_id gets one,
// as load_session does.
func Parse(raw []byte) *Session {
	value, err := rails.ParseJSON(raw)
	data, ok := value.(*rails.Hash)
	if err != nil || !ok {
		return nil
	}
	if v := data.Value(sessionIDKey); v == nil || v == false {
		data.Set(sessionIDKey, newSessionID())
	}
	return &Session{data: data}
}

func (s *Session) Get(key string) any {
	if s == nil {
		return nil
	}
	return s.data.Value(key)
}

// Set is session[key] = value. Values are what rails.EncodeJSON writes. A nil session is a
// NullSessionHash, which drops writes.
func (s *Session) Set(key string, value any) {
	if s != nil {
		s.data.Set(key, value)
	}
}

// Delete is session.delete(key).
func (s *Session) Delete(key string) {
	if s != nil {
		s.data.Delete(key)
	}
}

// JSON is the session as the cookie store writes it: nil values dropped, then
// ActiveSupport's JSON.
func (s *Session) JSON() []byte {
	out := rails.NewHash()
	for _, k := range s.data.Keys() {
		if v := s.data.Value(k); v != nil {
			out.Set(k, v)
		}
	}
	return []byte(rails.EncodeJSON(out))
}

// newSessionID is Rack's generate_sid: SecureRandom.hex(16).
func newSessionID() string {
	var b [16]byte
	rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// String returns a string value, or "" when the key is missing or not a string.
func (s *Session) String(key string) string {
	v, _ := s.Get(key).(string)
	return v
}

// CSRFTokenKey is session[:_csrf_token], where the cookie session store keeps the
// urlsafe Base64 real token.
const CSRFTokenKey = "_csrf_token"

func (s *Session) CSRFToken() (string, bool) {
	v, ok := s.Get(CSRFTokenKey).(string)
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
	scoped, _ := s.Get("warden.user.user.session").(*rails.Hash)
	if scoped == nil {
		return 0, false
	}
	switch v := scoped.Value("last_sign_in_at").(type) {
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

// IsMobile is ApplicationController#is_mobile?: session[:mobile_param] when it's set, else
// whether the user agent says Mobile or webOS.
func (s *Session) IsMobile(userAgent string) bool {
	if param := s.Get("mobile_param"); rails.Truthy(param) {
		return param == "1"
	}
	return strings.Contains(userAgent, "Mobile") || strings.Contains(userAgent, "webOS")
}
