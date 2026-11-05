package storage

import "testing"

// The digests are Ruby's OpenSSL::Digest::SHA1.base64digest(Marshal.dump(...)) for the
// transformations each blob gets; production's variant records carry the same.
func TestVariationDigestMatchesRuby(t *testing.T) {
	const jpg, png, upperJPG = "AdwUXi+6z9A47bVAPl6DRy8ePAI=", "DPLEjjKtMBtQhSEkLq14yIJ2Uxc=", "Zt7HQoDjMha0Pu++ZKOMyb+QZ40="
	for _, c := range []struct{ filename, contentType, want string }{
		{"photo.jpg", "image/jpeg", jpg},
		// The extension Marcel agrees with is kept as written.
		{"photo.JPG", "image/jpeg", upperJPG},
		// No extension, or one that names another type: Marcel's first extension.
		{"photo", "image/jpeg", jpg},
		{"photo.png", "image/jpeg", jpg},
		// Not a web image: :png.
		{"photo.webp", "image/webp", png},
		{"photo.heic", "image/heic", png},
	} {
		if got := variationDigest(c.filename, c.contentType); got != c.want {
			t.Errorf("%s %s: got %s, want %s", c.filename, c.contentType, got, c.want)
		}
	}
}
