// Package sessiontest writes what a browser carries back to Rails, for tests: an encrypted
// cookie under the primary key, and the masked CSRF token the meta tag holds.
package sessiontest

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"testing"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// Encrypt writes value (JSON) as the encrypted cookie jar does. A zero expiresAt leaves
// the expiry null.
func Encrypt(t testing.TB, secretKeyBase, name string, value []byte, expiresAt time.Time) string {
	t.Helper()
	key, err := pbkdf2.Key(sha256.New, secretKeyBase, []byte("authenticated encrypted cookie"), 1000, 32)
	if err != nil {
		t.Fatal(err)
	}
	block, _ := aes.NewCipher(key)
	aead, _ := cipher.NewGCM(block)
	expiry := []byte("null")
	if !expiresAt.IsZero() {
		expiry, _ = json.Marshal(expiresAt.UTC().Format("2006-01-02T15:04:05.000Z07:00"))
	}
	purpose, _ := json.Marshal("cookie." + name)
	// Rails recognizes this envelope by its prefix, so the key order matters.
	envelope := `{"_rails":{"message":"` + base64.StdEncoding.EncodeToString(value) + `","exp":` + string(expiry) + `,"pur":` + string(purpose) + `}}`
	iv := make([]byte, aead.NonceSize())
	rand.Read(iv)
	sealed := aead.Seal(nil, iv, []byte(envelope), nil)
	body, tag := sealed[:len(sealed)-aead.Overhead()], sealed[len(sealed)-aead.Overhead():]
	enc := base64.StdEncoding
	return enc.EncodeToString(body) + "--" + enc.EncodeToString(iv) + "--" + enc.EncodeToString(tag)
}

// MaskedGlobalToken is form_authenticity_token for the session's real token.
func MaskedGlobalToken(realToken string) string {
	real, _ := rails.URLSafeDecode64(realToken)
	mac := hmac.New(sha256.New, real)
	mac.Write([]byte("!real_csrf_token"))
	raw := mac.Sum(nil)
	pad := make([]byte, len(raw))
	rand.Read(pad)
	masked := append(append([]byte{}, pad...), raw...)
	for i := range raw {
		masked[len(raw)+i] ^= pad[i]
	}
	return base64.RawURLEncoding.EncodeToString(masked)
}
