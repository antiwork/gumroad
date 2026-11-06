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
		// Wider w_long values, then Bignums from 2**30.
		{"a.bmp", "image/bmp", 70_000, 1 << 31, "PWG+TOdhPohr5rtt2yJskXGmEvE="},
		{"a.png", "image/png", 300, 1<<30 - 1, "D35zOCe/9Y0Ic42PKEKa0cs3UGQ="},
		{"a.png", "image/png", 1 << 30, 1 << 24, "LdUn3CF0eqBATvovnJ6kCM9aVLg="},
		{"a.bmp", "image/bmp", 1<<40 + 5, 123, "yX2kH0AbSxBsfoyUiNPbgBsCf6I="},
	} {
		if got := VariantDigest(c.filename, c.contentType, c.width, c.height); got != c.want {
			t.Errorf("%s %d×%d: %s, want %s", c.filename, c.width, c.height, got, c.want)
		}
	}
}
