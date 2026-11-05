package session

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/session/sessiontest"
)

type railsCookies struct {
	SecretKeyBase       string         `json:"secret_key_base"`
	SessionCookie       string         `json:"session_cookie"`
	SessionPlaintext    map[string]any `json:"session_plaintext"`
	CurrentSellerCookie string         `json:"current_seller_cookie"`
	RotatedCookie       string         `json:"rotated_cookie"`
	RotatedReadBack     any            `json:"rotated_read_back"`
	ExpiredCookie       string         `json:"expired_cookie"`
	WrongPurposeCookie  string         `json:"wrong_purpose_cookie"`
	NoMetadataCookie    string         `json:"no_metadata_cookie"`
	NoMetadataReadBack  any            `json:"no_metadata_read_back"`
	WrittenSession      struct {
		SetCookie string `json:"set_cookie"`
		Envelope  string `json:"envelope"`
	} `json:"written_session"`
	CSRFCases []struct {
		Name     string
		Token    string
		Path     string
		Origin   *string
		Verified bool
	} `json:"csrf_cases"`
}

func loadRailsCookies(t *testing.T) (railsCookies, *Codec) {
	t.Helper()
	data, err := os.ReadFile("testdata/rails_cookies.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixtures railsCookies
	if err := json.Unmarshal(data, &fixtures); err != nil {
		t.Fatal(err)
	}
	codec, err := NewCodec(fixtures.SecretKeyBase)
	if err != nil {
		t.Fatal(err)
	}
	return fixtures, codec
}

// Every fixture was written with an expiry Rails computed when it ran, so read as of then.
var fixtureTime = time.Date(2026, 11, 2, 0, 0, 0, 0, time.UTC)

func TestDecryptsTheSessionCookieRailsWrote(t *testing.T) {
	fixtures, codec := loadRailsCookies(t)
	raw, ok := codec.Decrypt("_gumroad_app_session", fixtures.SessionCookie, fixtureTime)
	if !ok {
		t.Fatal("Rails' own session cookie did not decrypt")
	}
	var got map[string]any
	json.Unmarshal(raw, &got)
	if !reflect.DeepEqual(got, fixtures.SessionPlaintext) {
		t.Fatalf("got %v\nwant %v", got, fixtures.SessionPlaintext)
	}

	s := codec.Load("_gumroad_app_session", fixtures.SessionCookie, fixtureTime)
	if id, ok := s.WardenUser(); !ok || id != 1_000_001 {
		t.Errorf("WardenUser = %d %v", id, ok)
	}
	if at, ok := s.LastSignInAt(); !ok || at != 1_790_000_000 {
		t.Errorf("LastSignInAt = %d %v", at, ok)
	}
	if token, ok := s.CSRFToken(); !ok || token != fixtures.SessionPlaintext["_csrf_token"] {
		t.Errorf("CSRFToken = %q", token)
	}
	if s.String("mobile_param") != "1" || s.String("signup_referrer") != "www.google.com" {
		t.Errorf("session strings = %q %q", s.String("mobile_param"), s.String("signup_referrer"))
	}
}

func TestDecryptRejectsWhatTheCookieJarRejects(t *testing.T) {
	fixtures, codec := loadRailsCookies(t)
	read := func(value string) any {
		raw, ok := codec.Decrypt("_gumroad_app_session", value, fixtureTime)
		if !ok {
			return nil
		}
		var v map[string]any
		json.Unmarshal(raw, &v)
		return v["warden.user.user.key"]
	}
	if got := read(fixtures.RotatedCookie); !reflect.DeepEqual(got, fixtures.RotatedReadBack) {
		t.Errorf("cookie_rotator's SHA1 key: got %v, want %v", got, fixtures.RotatedReadBack)
	}
	if got := read(fixtures.NoMetadataCookie); !reflect.DeepEqual(got, fixtures.NoMetadataReadBack) {
		t.Errorf("a message without metadata: got %v, want %v", got, fixtures.NoMetadataReadBack)
	}
	if read(fixtures.ExpiredCookie) != nil || read(fixtures.WrongPurposeCookie) != nil {
		t.Error("expired and wrong-purpose cookies must read as nil")
	}
	for _, bad := range []string{"", "--", "garbage", fixtures.SessionCookie[:len(fixtures.SessionCookie)-3] + "AA=", fixtures.SessionCookie + "x"} {
		if read(bad) != nil {
			t.Errorf("%q decrypted", bad)
		}
	}
	if _, ok := codec.Decrypt("other_cookie", fixtures.SessionCookie, fixtureTime); ok {
		t.Error("a cookie must not decrypt under another cookie's name")
	}
}

func TestDecryptsTheCurrentSellerCookie(t *testing.T) {
	fixtures, codec := loadRailsCookies(t)
	raw, ok := codec.Decrypt(CurrentSellerCookie, fixtures.CurrentSellerCookie, fixtureTime)
	if id, valid := cookieID(raw); !ok || !valid || id != 1_000_002 {
		t.Fatalf("got %s %v", raw, ok)
	}
	// cookies.permanent sets the expiry after the encrypted jar has sealed the message.
	if _, ok := codec.Decrypt(CurrentSellerCookie, fixtures.CurrentSellerCookie, fixtureTime.AddDate(30, 0, 0)); !ok {
		t.Error("the message itself carries no expiry")
	}
}

func TestSessiontestEncryptWritesWhatDecryptReads(t *testing.T) {
	fixtures, codec := loadRailsCookies(t)
	value := sessiontest.Encrypt(t, fixtures.SecretKeyBase, "_gumroad_app_session", []byte(`{"a":1}`), fixtureTime.Add(time.Hour))
	if raw, ok := codec.Decrypt("_gumroad_app_session", value, fixtureTime); !ok || string(raw) != `{"a":1}` {
		t.Fatalf("got %s %v", raw, ok)
	}
	if _, ok := codec.Decrypt("_gumroad_app_session", value, fixtureTime.Add(2*time.Hour)); ok {
		t.Error("expired")
	}
	if codec.Load("_gumroad_app_session", sessiontest.Encrypt(t, fixtures.SecretKeyBase, "_gumroad_app_session", []byte(`{"a":`), time.Time{}), fixtureTime) != nil {
		t.Error("a cookie whose JSON doesn't parse is an empty session")
	}
}

func TestValidAuthenticityTokenMatchesRails(t *testing.T) {
	fixtures, _ := loadRailsCookies(t)
	real := fixtures.SessionPlaintext["_csrf_token"].(string)
	for _, c := range fixtures.CSRFCases {
		// Origin checks happen before the token check; see the beacons package.
		if c.Origin != nil && *c.Origin != "https://gumroad.com" {
			continue
		}
		if got := ValidAuthenticityToken(real, c.Token, c.Path, "POST"); got != c.Verified {
			t.Errorf("%s on %s: got %v, Rails %v", c.Name, c.Path, got, c.Verified)
		}
	}
	if ValidAuthenticityToken("", sessiontest.MaskedGlobalToken(real), "/x", "POST") {
		t.Error("without a session token nothing verifies")
	}
	if !ValidAuthenticityToken(real, sessiontest.MaskedGlobalToken(real), "/anything/", "PATCH") {
		t.Error("the masked global token verifies everywhere")
	}
}

func TestCookieNameFollowsSessionStore(t *testing.T) {
	for _, c := range []struct {
		env, domain string
		branch      bool
		want        string
	}{
		{"production", "", false, "_gumroad_app_session"},
		{"staging", "", false, "_gumroad_app_session_staging"},
		{"staging", "pr-1.apps.staging.gumroad.org", true, "_gumroad_app_session_" + sha256Hex("pr-1.apps.staging.gumroad.org")[:32]},
		{"development", "", false, "_gumroad_app_session_development"},
	} {
		if got := CookieName(c.env, c.domain, c.branch); got != c.want {
			t.Errorf("CookieName(%s) = %s, want %s", c.env, got, c.want)
		}
	}
}
