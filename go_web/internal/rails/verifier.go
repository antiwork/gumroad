package rails

import (
	"bytes"
	"crypto/hmac"
	"crypto/pbkdf2"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"time"
)

// MessageVerifier is Rails.application.message_verifier(name): HMAC-SHA1 over strict
// Base64, under a key PBKDF2-SHA256 derives from secret_key_base with the name as salt,
// and the JSON serializer carrying its metadata in a {"_rails": ...} envelope.
type MessageVerifier struct {
	secret []byte
}

func NewMessageVerifier(secretKeyBase, name string) (*MessageVerifier, error) {
	secret, err := pbkdf2.Key(sha256.New, secretKeyBase, []byte(name), 1000, 64)
	if err != nil {
		return nil, err
	}
	return &MessageVerifier{secret: secret}, nil
}

const sha1HexLength = 40

func (v *MessageVerifier) digest(encoded string) string {
	mac := hmac.New(sha1.New, v.secret)
	mac.Write([]byte(encoded))
	return hex.EncodeToString(mac.Sum(nil))
}

// Verified is MessageVerifier#verified(token, purpose:). ok is false wherever Rails returns
// nil; data is the JSON of the message's payload.
func (v *MessageVerifier) Verified(token, purpose string, now time.Time) (json.RawMessage, bool) {
	sep := len(token) - sha1HexLength - 2
	if sep <= 0 || token[sep:sep+2] != "--" {
		return nil, false
	}
	encoded, digest := token[:sep], token[sep+2:]
	if subtle.ConstantTimeCompare([]byte(digest), []byte(v.digest(encoded))) != 1 {
		return nil, false
	}
	data, err := base64.StdEncoding.Strict().DecodeString(encoded)
	if err != nil {
		return nil, false
	}
	if bytes.HasPrefix(data, []byte(legacyEnvelopePrefix)) {
		message, ok := checkEnvelope(data, purpose, now, "message")
		if !ok {
			return nil, false
		}
		var inner string
		if json.Unmarshal(message, &inner) != nil {
			return nil, false
		}
		decoded, err := base64.StdEncoding.Strict().DecodeString(inner)
		if err != nil || !json.Valid(decoded) {
			return nil, false
		}
		return decoded, true
	}
	if !json.Valid(data) {
		return nil, false
	}
	return checkEnvelope(data, purpose, now, "data")
}

const legacyEnvelopePrefix = `{"_rails":{"message":`

// checkEnvelope is extract_from_metadata_envelope: an expired or mismatched purpose reads
// as nil, and so does a message without metadata when a purpose is expected.
func checkEnvelope(data []byte, purpose string, now time.Time, field string) (json.RawMessage, bool) {
	var envelope struct {
		Rails map[string]json.RawMessage `json:"_rails"`
	}
	if json.Unmarshal(data, &envelope) != nil || envelope.Rails == nil {
		return nil, false
	}
	meta := envelope.Rails
	if raw, ok := meta["exp"]; ok && string(raw) != "null" {
		var exp string
		if json.Unmarshal(raw, &exp) != nil {
			return nil, false
		}
		at, err := time.Parse(time.RFC3339Nano, exp)
		if err != nil || !now.Before(at) {
			return nil, false
		}
	}
	var pur any
	if raw, ok := meta["pur"]; ok {
		json.Unmarshal(raw, &pur)
	}
	if ToS(pur) != purpose {
		return nil, false
	}
	payload, ok := meta[field]
	return payload, ok
}
