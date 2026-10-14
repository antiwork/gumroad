package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

// Resend's names for the events EmailEventInfo::TRACKED_EVENTS handles.
var trackedEventTypes = map[string]bool{
	"email.bounced":    true,
	"email.delivered":  true,
	"email.opened":     true,
	"email.clicked":    true,
	"email.complained": true,
}

// The headers ResendEventInfo#initialize decrypts, as MailerInfo.header_name builds them.
const (
	headerMailerClass  = "X-GUM-Mailer-Class"
	headerMailerMethod = "X-GUM-Mailer-Method"
	headerWorkflowIDs  = "X-GUM-Workflow-Ids"
)

var decryptedHeaders = []string{
	headerMailerClass,
	headerMailerMethod,
	"X-GUM-Mailer-Args",
	"X-GUM-Purchase-Id",
	"X-GUM-Charge-Id",
	headerWorkflowIDs,
	"X-GUM-Post-Id",
}

// Layouts of Resend's data.created_at. Rails' Time.zone.parse accepts more, so an
// unparseable value is enqueued rather than judged.
var createdAtLayouts = []string{"2006-01-02 15:04:05.999999999-07", "2006-01-02 15:04:05.999999999-07:00", time.RFC3339Nano}

var errMalformed = errors.New("malformed event")

// eventFilter ports ForeignWebhooksController#trackable_resend_event?. It drops an
// event only when ResendEventInfo would build it and call it invalid; anything it
// can't evaluate is enqueued, and HandleResendEventJob decides.
type eventFilter struct {
	// AES-256 keyed by SHA-256 of MAILER_HEADERS_ENCRYPTION_KEY_V1. Nil when the key is
	// unset, in which case decryption raises in Rails too and every event is enqueued.
	block cipher.Block
}

func newEventFilter(rawKey string) *eventFilter {
	if rawKey == "" {
		return &eventFilter{}
	}
	key := sha256.Sum256([]byte(rawKey))
	block, _ := aes.NewCipher(key[:]) // a 32-byte key cannot fail
	return &eventFilter{block: block}
}

func (f *eventFilter) trackable(event map[string]any) bool {
	invalid, err := f.invalid(event)
	return err != nil || !invalid
}

func (f *eventFilter) invalid(event map[string]any) (bool, error) {
	data, ok := event["data"].(map[string]any)
	if !ok {
		return false, errMalformed
	}
	switch data["to"].(type) {
	case []any, string, map[string]any:
	default:
		return false, errMalformed
	}
	switch data["click"].(type) {
	case nil, map[string]any:
	default:
		return false, errMalformed
	}
	if !parseableCreatedAt(data["created_at"]) {
		return false, errMalformed
	}

	values := make(map[string][]byte, len(decryptedHeaders))
	for _, name := range decryptedHeaders {
		value, err := f.headerValue(data["headers"], name)
		if err != nil {
			return false, err
		}
		values[name] = value
	}
	if workflowIDs := values[headerWorkflowIDs]; !blank(workflowIDs) && !json.Valid(workflowIDs) {
		return false, errMalformed
	}

	eventType, _ := event["type"].(string)
	return !trackedEventTypes[eventType] || blank(values[headerMailerClass]) || blank(values[headerMailerMethod]), nil
}

func parseableCreatedAt(value any) bool {
	s, ok := value.(string)
	if !ok {
		return false
	}
	for _, layout := range createdAtLayouts {
		if _, err := time.Parse(layout, s); err == nil {
			return true
		}
	}
	return false
}

// headerValue mirrors MailerInfo.parse_resend_webhook_header: the first header whose
// name matches case-insensitively, decrypted. A missing header or value is nil.
func (f *eventFilter) headerValue(headers any, name string) ([]byte, error) {
	var list []any
	switch h := headers.(type) {
	case nil:
		return nil, nil
	case []any:
		list = h
	case map[string]any:
		if len(h) == 0 {
			return nil, nil
		}
		return nil, errMalformed
	default:
		return nil, errMalformed
	}
	for _, item := range list {
		header, ok := item.(map[string]any)
		if !ok {
			return nil, errMalformed
		}
		headerName, ok := header["name"].(string)
		if !ok {
			return nil, errMalformed
		}
		if !strings.EqualFold(headerName, name) {
			continue
		}
		switch value := header["value"].(type) {
		case nil:
			return nil, nil
		case string:
			return f.decrypt(value)
		default:
			return nil, errMalformed
		}
	}
	return nil, nil
}

// decrypt mirrors MailerInfo::Encryption.decrypt for "v<version>:<iv>:<ciphertext>"
// values: AES-256-CBC with PKCS#7 padding, and version 1 is the only key.
func (f *eventFilter) decrypt(value string) ([]byte, error) {
	parts := rubySplit(value, ":")
	if len(parts) < 3 {
		return nil, errMalformed
	}
	if rubyToI(strings.TrimPrefix(parts[0], "v")) != 1 || f.block == nil {
		return nil, errMalformed
	}
	iv, err := strictDecode64(parts[1])
	if err != nil || len(iv) != aes.BlockSize {
		return nil, errMalformed
	}
	ciphertext, err := strictDecode64(parts[2])
	if err != nil || len(ciphertext) == 0 || len(ciphertext)%aes.BlockSize != 0 {
		return nil, errMalformed
	}
	plaintext := make([]byte, len(ciphertext))
	cipher.NewCBCDecrypter(f.block, iv).CryptBlocks(plaintext, ciphertext)
	padding := int(plaintext[len(plaintext)-1])
	if padding == 0 || padding > aes.BlockSize {
		return nil, errMalformed
	}
	for _, b := range plaintext[len(plaintext)-padding:] {
		if int(b) != padding {
			return nil, errMalformed
		}
	}
	return plaintext[:len(plaintext)-padding], nil
}
