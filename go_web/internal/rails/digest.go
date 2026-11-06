package rails

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"strconv"
)

// EmailDigest is Purchase#email_digest: the HMAC of "id:email" under OBFUSCATE_IDS_CIPHER_KEY,
// nil without an email.
func EmailDigest(key string, purchaseID int64, email string) any {
	if !Present(email) {
		return nil
	}
	mac := hmac.New(sha256.New, []byte(key))
	mac.Write([]byte(strconv.FormatInt(purchaseID, 10) + ":" + email))
	return base64.URLEncoding.EncodeToString(mac.Sum(nil))
}
