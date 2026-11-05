package session

import (
	"errors"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// maxCookieSize is ActionDispatch::Cookies::MAX_COOKIE_SIZE.
const maxCookieSize = 4096

// ErrCookieOverflow is ActionDispatch::Cookies::CookieOverflow, which Rails answers with a 500.
var ErrCookieOverflow = errors.New("session cookie overflowed")

// Store is config/initializers/session_store.rb's cookie store.
type Store struct {
	Codec *Codec
	Name  string
	// Secure is Rails.env.production?: the cookie is flagged Secure, and only an SSL
	// request commits it at all.
	Secure bool
	// HTTPS is PROTOCOL == "https", where SecureHeaders flags cookies on SSL requests.
	HTTPS bool
	// Domain is the explicit domain a branch deployment uses; empty means domain: :all.
	Domain    string
	TLDLength int
	// TenYears is the test environment's expire_after; elsewhere it is a month.
	TenYears bool
}

// NewStore takes the environment session_store.rb and secure_headers.rb read.
func NewStore(codec *Codec, railsEnv, protocol, customDomain string, branchDeployment bool) *Store {
	st := &Store{
		Codec: codec, Name: CookieName(railsEnv, customDomain, branchDeployment),
		Secure: railsEnv == "production", HTTPS: protocol == "https", TLDLength: 2, TenYears: railsEnv == "test",
	}
	if railsEnv == "staging" {
		st.TLDLength = 3
		if branchDeployment {
			st.Domain = "." + customDomain
		}
	}
	return st
}

// CommitLine is the Set-Cookie line commit_session writes for a loaded session, or "" where
// it writes none: no session (a NullSessionHash), or a secure store on a request that isn't
// SSL. The encrypted message expires with the cookie.
func (st *Store) CommitLine(s *Session, host string, ssl bool, now time.Time) (string, error) {
	if s == nil || (st.Secure && !ssl) {
		return "", nil
	}
	expires := rails.AddMonths(now, 1)
	if st.TenYears {
		expires = rails.AddYears(now, 10)
	}
	value := st.Codec.Encrypt(st.Name, s.JSON(), expires)
	if len(value) > maxCookieSize {
		return "", ErrCookieOverflow
	}
	domain := st.Domain
	if domain == "" {
		domain = rails.CookieDomainTLD(host, st.TLDLength)
	}
	return rails.SetCookie{Name: st.Name, Value: value, Domain: domain, Expires: expires, Secure: st.Secure, HTTPOnly: true}.
		Line(st.HTTPS && ssl), nil
}

// Load is the session the request's cookie carries, nil when there is none or it doesn't
// decrypt.
func (st *Store) Load(req *rails.Request) *Session {
	raw, ok := req.Cookie(st.Name)
	if !ok {
		return nil
	}
	return st.Codec.Load(st.Name, raw, req.Now)
}

// EncryptedCookie is cookies.encrypted[name] up to the JSON parse; see Codec.Decrypt.
func (st *Store) EncryptedCookie(req *rails.Request, name string) ([]byte, bool) {
	raw, ok := req.Cookie(name)
	if !ok {
		return nil, false
	}
	return st.Codec.Decrypt(name, raw, req.Now)
}
