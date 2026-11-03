// Package obfuscate is app/modules/obfuscate_ids.rb, byte for byte: AES-256-CBC with an
// all-zero IV (Ruby never sets one) under SHA-256 of the key, and the bit-reversing numeric
// scheme.
package obfuscate

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"strconv"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

const numericBits = 30

type IDs struct {
	block      cipher.Block
	numericKey string // NUMERIC_CIPHER_KEY.to_s(2), not left-padded, as Ruby's xor reads it
}

// New takes OBFUSCATE_IDS_CIPHER_KEY and OBFUSCATE_IDS_NUMERIC_CIPHER_KEY as Rails reads them.
func New(cipherKey, numericCipherKey string) (*IDs, error) {
	if cipherKey == "" {
		return nil, errors.New("OBFUSCATE_IDS_CIPHER_KEY is not set")
	}
	key := sha256.Sum256([]byte(cipherKey))
	block, err := aes.NewCipher(key[:])
	if err != nil {
		return nil, err
	}
	numericKey, _ := rails.StringToI(numericCipherKey)
	return &IDs{block: block, numericKey: strconv.FormatInt(numericKey, 2)}, nil
}

// Encrypt is ObfuscateIds.encrypt(id) with the default padding.
func (o *IDs) Encrypt(id int64) string {
	plain := []byte(strconv.FormatInt(id, 10))
	pad := aes.BlockSize - len(plain)%aes.BlockSize
	for range pad {
		plain = append(plain, byte(pad))
	}
	out := make([]byte, len(plain))
	cipher.NewCBCEncrypter(o.block, make([]byte, aes.BlockSize)).CryptBlocks(out, plain)
	return base64.URLEncoding.EncodeToString(out)
}

// Decrypt is ObfuscateIds.decrypt; ok is false where Ruby returns nil, and for a plaintext
// whose to_i is a Bignum, which matches no row either.
func (o *IDs) Decrypt(external string) (int64, bool) {
	data, ok := rails.URLSafeDecode64(external)
	if !ok || len(data) == 0 || len(data)%aes.BlockSize != 0 {
		return 0, false
	}
	plain := make([]byte, len(data))
	cipher.NewCBCDecrypter(o.block, make([]byte, aes.BlockSize)).CryptBlocks(plain, data)
	pad := int(plain[len(plain)-1])
	if pad == 0 || pad > aes.BlockSize {
		return 0, false
	}
	for _, b := range plain[len(plain)-pad:] {
		if int(b) != pad {
			return 0, false
		}
	}
	return rails.StringToI(string(plain[:len(plain)-pad]))
}

// EncryptNumeric is ObfuscateIds.encrypt_numeric. ok is false where Ruby raises.
func (o *IDs) EncryptNumeric(id int64) (int64, bool) {
	if id < 0 || id > 1<<numericBits-1 {
		return 0, false
	}
	padded := leftPad(strconv.FormatInt(id, 2), numericBits)
	return parseBinary(reverse(xor(padded, o.numericKey))), true
}

// DecryptNumeric is ObfuscateIds.decrypt_numeric.
func (o *IDs) DecryptNumeric(encrypted int64) int64 {
	binary := reverse(leftPad(strconv.FormatInt(encrypted, 2), numericBits))
	return parseBinary(xor(binary, o.numericKey))
}

// xor mirrors the Ruby helper: n index-aligned characters, a missing character reading as 0.
func xor(a, b string) string {
	var out strings.Builder
	for i := range numericBits {
		out.WriteByte('0' + (bit(a, i) ^ bit(b, i)))
	}
	return out.String()
}

func bit(s string, i int) byte {
	if i < len(s) && s[i] == '1' {
		return 1
	}
	return 0
}

func leftPad(s string, n int) string {
	if len(s) >= n {
		return s
	}
	return strings.Repeat("0", n-len(s)) + s
}

func reverse(s string) string {
	b := []byte(s)
	for i, j := 0, len(b)-1; i < j; i, j = i+1, j-1 {
		b[i], b[j] = b[j], b[i]
	}
	return string(b)
}

func parseBinary(s string) int64 {
	n, _ := strconv.ParseInt(s, 2, 64)
	return n
}
