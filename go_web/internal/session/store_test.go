package session

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// writtenFixture is the session Rails wrote for a request without one: its JSON, the
// envelope that JSON was sealed in, and the envelope's expiry.
func writtenFixture(t *testing.T, fixtures railsCookies) (value []byte, expires time.Time) {
	t.Helper()
	var envelope struct {
		Rails struct{ Message, Exp string } `json:"_rails"`
	}
	if err := json.Unmarshal([]byte(fixtures.WrittenSession.Envelope), &envelope); err != nil {
		t.Fatal(err)
	}
	value, _ = base64.StdEncoding.DecodeString(envelope.Rails.Message)
	expires, err := time.Parse(time.RFC3339Nano, envelope.Rails.Exp)
	if err != nil {
		t.Fatal(err)
	}
	return value, expires
}

// openEnvelope decrypts a cookie under the primary key without reading the envelope.
func openEnvelope(t *testing.T, codec *Codec, value string) string {
	t.Helper()
	sealed, iv, ok := rails.SplitEncryptedMessage(value)
	if !ok {
		t.Fatalf("not an encrypted message: %q", value)
	}
	plain, err := codec.aeads[0].Open(nil, iv, sealed, nil)
	if err != nil {
		t.Fatal(err)
	}
	return string(plain)
}

func TestSessionJSONIsWhatTheCookieStoreWrites(t *testing.T) {
	fixtures, _ := loadRailsCookies(t)
	value, _ := writtenFixture(t, fixtures)
	s := Parse(value)
	if got := string(s.JSON()); got != string(value) {
		t.Fatalf("re-encoded session\n got %s\nwant %s", got, value)
	}
	referrer := `"signup_referrer":` + rails.EncodeJSON(s.String("signup_referrer"))
	s.Set("dropped", nil)
	s.Set("signup_referrer", "x")
	s.Delete("recommender_model_name")
	want := strings.Replace(strings.Replace(string(value), `"recommender_model_name":"sales",`, "", 1), referrer, `"signup_referrer":"x"`, 1)
	if got := string(s.JSON()); got != want {
		t.Errorf("after edits\n got %s\nwant %s", got, want)
	}
}

func TestEncryptSealsTheEnvelopeRailsSeals(t *testing.T) {
	fixtures, codec := loadRailsCookies(t)
	value, expires := writtenFixture(t, fixtures)
	sealed := codec.Encrypt("_gumroad_app_session", value, expires)
	if got := openEnvelope(t, codec, sealed); got != fixtures.WrittenSession.Envelope {
		t.Fatalf("envelope\n got %s\nwant %s", got, fixtures.WrittenSession.Envelope)
	}
	if raw, ok := codec.Decrypt("_gumroad_app_session", sealed, expires.Add(-time.Second)); !ok || string(raw) != string(value) {
		t.Error("the reader must accept what the writer sealed")
	}
	if _, ok := codec.Decrypt("_gumroad_app_session", sealed, expires); ok {
		t.Error("the message expires with the cookie")
	}
	if codec.Encrypt("_gumroad_app_session", value, expires) == sealed {
		t.Error("every seal takes a fresh IV")
	}
}

func TestCommitLineIsTheSetCookieRailsWrites(t *testing.T) {
	fixtures, codec := loadRailsCookies(t)
	value, expires := writtenFixture(t, fixtures)
	st := NewStore(codec, "production", "https", "", false)
	// The cookie expires a calendar month after the commit; the fixture's envelope says when.
	now := expires.AddDate(0, -1, 0)
	line, err := st.CommitLine(Parse(value), "gumroad.com", true, now)
	if err != nil {
		t.Fatal(err)
	}
	name, attrs, _ := strings.Cut(line, ";")
	wantName, wantAttrs, _ := strings.Cut(fixtures.WrittenSession.SetCookie, ";")
	if attrs != wantAttrs || !strings.HasPrefix(name, "_gumroad_app_session=") || !strings.HasPrefix(wantName, "_gumroad_app_session=") {
		t.Fatalf("got %q\nwant %q", line, fixtures.WrittenSession.SetCookie)
	}
	escaped := strings.TrimPrefix(name, "_gumroad_app_session=")
	if strings.ContainsAny(escaped, "+/=") {
		t.Errorf("the value must be Rack-escaped: %q", escaped)
	}
	for _, c := range []struct {
		host string
		ssl  bool
		want string
	}{
		{"seller.gumroad.com", true, "; domain=gumroad.com;"},
		{"shop.example.co.uk", true, "; domain=co.uk;"},
		{"10.0.0.1", true, "; path=/;"},
		{"gumroad.com", false, ""},
		{"evil.com;samesite=none", true, "; path=/;"},
	} {
		got, _ := st.CommitLine(Parse(value), c.host, c.ssl, now)
		if (c.want == "") != (got == "") || (c.want != "" && !strings.Contains(got, c.want)) {
			t.Errorf("%s ssl=%v: %q, want it to contain %q", c.host, c.ssl, got, c.want)
		}
	}
	if got, _ := st.CommitLine(nil, "gumroad.com", true, now); got != "" {
		t.Error("no session, no cookie")
	}
	big := Parse(value)
	big.Set("signup_referrer", strings.Repeat("x", maxCookieSize))
	if _, err := st.CommitLine(big, "gumroad.com", true, now); err != ErrCookieOverflow {
		t.Errorf("an oversized session: %v", err)
	}
	var null *Session
	null.Set("a", "b")
	null.Delete("a")
}

func TestNewSessionsStartWithASessionID(t *testing.T) {
	s := New()
	if keys := s.data.Keys(); len(keys) != 1 || keys[0] != "session_id" || len(s.String("session_id")) != 32 {
		t.Fatalf("got %v", keys)
	}
	if New().String("session_id") == s.String("session_id") {
		t.Error("session ids are random")
	}
	if got := Parse([]byte(`{"a":1}`)); got.data.Keys()[1] != "session_id" || len(got.String("session_id")) != 32 {
		t.Errorf("a session without an id gets one after its keys: %v", got.data.Keys())
	}
}

func TestMaskedGlobalTokenVerifiesAndVaries(t *testing.T) {
	real := GenerateCSRFToken()
	if raw, err := base64.RawURLEncoding.DecodeString(real); err != nil || len(raw) != 32 || len(real) != 43 {
		t.Fatalf("real token %q", real)
	}
	first, ok := MaskedGlobalToken(real)
	second, _ := MaskedGlobalToken(real)
	if !ok || len(first) != 86 || first == second {
		t.Fatalf("masked tokens %q %q", first, second)
	}
	for _, token := range []string{first, second} {
		if !ValidAuthenticityToken(real, token, "/any/path", "POST") {
			t.Errorf("%q does not verify", token)
		}
	}
	if ValidAuthenticityToken(GenerateCSRFToken(), first, "/x", "POST") {
		t.Error("a token must not verify against another session")
	}
	if _, ok := MaskedGlobalToken("not base64!"); ok {
		t.Error("a real token that isn't Base64 is refused")
	}
}

func TestRotatedSpotsCookiesUnderTheOldKey(t *testing.T) {
	fixtures, codec := loadRailsCookies(t)
	if !codec.Rotated("_gumroad_app_session", fixtures.RotatedCookie) {
		t.Error("cookie_rotator's SHA1 key")
	}
	if codec.Rotated("_gumroad_app_session", fixtures.SessionCookie) || codec.Rotated("_gumroad_app_session", "garbage") {
		t.Error("the primary key, and a cookie that opens under neither")
	}
}

// The envelope Rails 8.1's cookie jar writes for cookies.encrypted[:confirmed_redirect] =
// { value: "tok123", httponly: true }, decrypted.
func TestEncryptWithoutExpiryMatchesRails(t *testing.T) {
	c, err := NewCodec("probe-secret")
	if err != nil {
		t.Fatal(err)
	}
	sealed, iv, ok := rails.SplitEncryptedMessage(c.Encrypt("confirmed_redirect", []byte(`"tok123"`), time.Time{}))
	if !ok {
		t.Fatal("not an encrypted message")
	}
	plain, err := c.aeads[0].Open(nil, iv, sealed, nil)
	if err != nil {
		t.Fatal(err)
	}
	if want := `{"_rails":{"message":"InRvazEyMyI=","exp":null,"pur":"cookie.confirmed_redirect"}}`; string(plain) != want {
		t.Errorf("got %s\nwant %s", plain, want)
	}
}
