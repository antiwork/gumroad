package rails

import "encoding/base64"

const (
	// MessageEncryptor's AES-GCM IV and auth tag sizes, which aes-128-gcm and aes-256-gcm share.
	encryptorIVLength  = 12
	encryptorTagLength = 16

	encryptorSeparator = "--"
	// Base64 lengths of the IV and auth tag, padding included.
	encodedIVLength  = 16
	encodedTagLength = 24
)

// SplitEncryptedMessage is MessageEncryptor#extract_parts for an AEAD cipher: the tag and IV
// are cut from the right by their encoded lengths, and every part must be strict Base64. It
// returns the ciphertext with the tag after it, in one buffer, as AEAD.Open takes them.
func SplitEncryptedMessage(message string) (sealed, iv []byte, ok bool) {
	tagStart := len(message) - encodedTagLength
	ivStart := tagStart - len(encryptorSeparator) - encodedIVLength
	dataEnd := ivStart - len(encryptorSeparator)
	if dataEnd < 0 || message[tagStart-len(encryptorSeparator):tagStart] != encryptorSeparator || message[dataEnd:ivStart] != encryptorSeparator {
		return nil, nil, false
	}
	strict := base64.StdEncoding.Strict()
	sealed = make([]byte, strict.DecodedLen(dataEnd)+encryptorTagLength)
	n, err := strict.Decode(sealed, []byte(message[:dataEnd]))
	if err != nil {
		return nil, nil, false
	}
	tag, err := strict.DecodeString(message[tagStart:])
	if err != nil || len(tag) != encryptorTagLength {
		return nil, nil, false
	}
	sealed = append(sealed[:n], tag...)
	if iv, err = strict.DecodeString(message[ivStart : ivStart+encodedIVLength]); err != nil || len(iv) != encryptorIVLength {
		return nil, nil, false
	}
	return sealed, iv, true
}

// JoinEncryptedMessage is MessageEncryptor's AEAD output: the ciphertext, IV and auth tag
// in strict Base64. sealed is what AEAD.Seal returns, the tag last.
func JoinEncryptedMessage(sealed, iv []byte) string {
	enc := base64.StdEncoding
	data, tag := sealed[:len(sealed)-encryptorTagLength], sealed[len(sealed)-encryptorTagLength:]
	return enc.EncodeToString(data) + encryptorSeparator + enc.EncodeToString(iv) + encryptorSeparator + enc.EncodeToString(tag)
}
