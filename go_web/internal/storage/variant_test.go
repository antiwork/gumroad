package storage

import "testing"

// Ruby: Base64.strict_encode64(Digest::SHA1.digest(Marshal.dump(transformations))).
func TestVariantDigestMatchesRubysMarshal(t *testing.T) {
	for _, c := range []struct {
		filename, contentType string
		width, height         int
		want                  string
	}{
		{"a.jpg", "image/jpeg", 1005, -1, "WX6OQ3hf/g9WoAI2n/sUdFF1vxA="}, // {format: "jpg", resize_to_limit: [1005, nil]}
		{"a.bmp", "image/bmp", 600, 600, "B5GjqkNnotBsCn2Kk7GJXVjrdrk="},  // {format: :png, resize_to_limit: [600, 600]}
		{"a.png", "image/png", 42, -1, "rnUnbwFFbDdb4KbxqJ21AJCAijo="},    // {format: "png", resize_to_limit: [42, nil]}
	} {
		if got := VariantDigest(c.filename, c.contentType, c.width, c.height); got != c.want {
			t.Errorf("%s %d×%d: %s, want %s", c.filename, c.width, c.height, got, c.want)
		}
	}
}
