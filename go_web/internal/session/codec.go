// Package session reads and writes Rails' encrypted cookies and resolves the signed-in user
// the way Devise, Warden and ApplicationController's LoggedInUser, Impersonate and
// CurrentSeller concerns do.
package session

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"hash"
	"strings"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

const (
	// ActionDispatch's authenticated_encrypted_cookie_salt default.
	encryptedCookieSalt = "authenticated encrypted cookie"
	keyIterations       = 1000
	keyLength           = 32
	// ActiveSupport::Messages::Metadata's dual-serialized envelope, which the cookie jar
	// writes because its encryptor's serializer is the NullSerializer.
	legacyEnvelopePrefix = `{"_rails":{"message":`
)

// Codec is the encrypted cookie jar: AES-256-GCM under the PBKDF2-SHA256 key Rails 8.1
// derives from secret_key_base, then the SHA1 key config/initializers/cookie_rotator.rb
// keeps accepting.
type Codec struct {
	aeads []cipher.AEAD
}

func NewCodec(secretKeyBase string) (*Codec, error) {
	if secretKeyBase == "" {
		return nil, errors.New("SECRET_KEY_BASE is not set")
	}
	c := &Codec{}
	for _, digest := range []func() hash.Hash{sha256.New, sha1.New} {
		key, err := pbkdf2.Key(digest, secretKeyBase, []byte(encryptedCookieSalt), keyIterations, keyLength)
		if err != nil {
			return nil, err
		}
		block, err := aes.NewCipher(key)
		if err != nil {
			return nil, err
		}
		aead, err := cipher.NewGCM(block)
		if err != nil {
			return nil, err
		}
		c.aeads = append(c.aeads, aead)
	}
	return c, nil
}

// Decrypt is cookies.encrypted[name] up to the jar's JSON serializer: it returns the bytes
// the jar would hand JSON.parse, or ok=false wherever Rails reads nil. Callers decode them,
// and treat JSON that fails to decode as nil too. value is the cookie after Rack unescaped it.
func (c *Codec) Decrypt(name, value string, now time.Time) ([]byte, bool) {
	sealed, iv, ok := rails.SplitEncryptedMessage(value)
	if !ok {
		return nil, false
	}
	// One plaintext buffer for both keys; it doesn't overlap sealed, which a failed Open
	// would otherwise leave clobbered for the next key.
	buf := make([]byte, 0, len(sealed))
	for _, aead := range c.aeads {
		plain, err := aead.Open(buf, iv, sealed, nil)
		if err != nil {
			continue
		}
		return extractMetadata(plain, "cookie."+name, now)
	}
	return nil, false
}

// Rotated is a cookie that opens only under cookie_rotator.rb's old key, which the cookie jar
// answers by writing it again under the primary key.
func (c *Codec) Rotated(name, value string) bool {
	sealed, iv, ok := rails.SplitEncryptedMessage(value)
	if !ok || len(c.aeads) < 2 {
		return false
	}
	if _, err := c.aeads[0].Open(nil, iv, sealed, nil); err == nil {
		return false
	}
	_, err := c.aeads[1].Open(nil, iv, sealed, nil)
	return err == nil
}

// extractMetadata is AbstractCookieJar#[]: Rails first expects the cookie's purpose, then
// retries with none, so a message without metadata is still accepted.
func extractMetadata(plain []byte, purpose string, now time.Time) ([]byte, bool) {
	if !bytes.HasPrefix(plain, []byte(legacyEnvelopePrefix)) {
		return plain, true
	}
	var envelope struct {
		Rails struct {
			Message *string `json:"message"`
			Exp     any     `json:"exp"`
			Pur     any     `json:"pur"`
		} `json:"_rails"`
	}
	if err := json.Unmarshal(plain, &envelope); err != nil || envelope.Rails.Message == nil {
		return nil, false
	}
	meta := envelope.Rails
	if exp, ok := meta.Exp.(string); ok {
		at, err := time.Parse(time.RFC3339Nano, exp)
		if err != nil || !now.Before(at) {
			return nil, false
		}
	}
	if pur := rubyToS(meta.Pur); pur != purpose && pur != "" {
		return nil, false
	}
	data, err := base64.StdEncoding.Strict().DecodeString(*meta.Message)
	if err != nil {
		return nil, false
	}
	return data, true
}

func rubyToS(v any) string {
	switch v := v.(type) {
	case nil:
		return ""
	case string:
		return v
	default:
		b, _ := json.Marshal(v)
		return strings.Trim(string(b), `"`)
	}
}

// Encrypt seals value, already JSON, as cookies.encrypted[name] does: in the legacy metadata
// envelope with the cookie's purpose and expiry, under the primary key. A zero expiresAt is a
// cookie without one, whose envelope carries "exp":null.
func (c *Codec) Encrypt(name string, value []byte, expiresAt time.Time) string {
	exp := "null"
	if !expiresAt.IsZero() {
		exp = `"` + expiresAt.UTC().Format("2006-01-02T15:04:05.000Z") + `"`
	}
	// Rails detects this envelope by its prefix, so the key order matters.
	envelope := legacyEnvelopePrefix + `"` + base64.StdEncoding.EncodeToString(value) + `","exp":` + exp +
		`,"pur":` + rails.EncodeJSON("cookie."+name) + `}}`
	aead := c.aeads[0]
	iv := make([]byte, aead.NonceSize())
	rand.Read(iv)
	return rails.JoinEncryptedMessage(aead.Seal(nil, iv, []byte(envelope), nil), iv)
}
