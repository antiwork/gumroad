// Package storage builds the Active Storage URLs Rails pages show: a user's avatar.
package storage

import (
	"bytes"
	"context"
	"crypto/sha1"
	"database/sql"
	"encoding/base64"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"

	"golang.org/x/sync/singleflight"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// ErrUnported is an avatar whose URL only Rails can give: one it would resize first, or
// whose resized file has gone from storage.
var ErrUnported = errors.New("an avatar URL this port leaves to Rails")

// User::AVATAR_VARIANT_PRESENCE_CACHE_TTL.
const presenceTTL = 5 * time.Minute

// Exister is service.exist?(key) on the public storage bucket.
type Exister interface {
	Exists(ctx context.Context, key string) (bool, error)
}

// Avatars is User#avatar_url.
type Avatars struct {
	DB     *sql.DB
	Exists Exister
	// AssetHost is config.asset_host, and PublicCDN what CDN_URL_MAP turns the public
	// service's object URL prefix into.
	AssetHost, PublicCDN string
	Now                  func() time.Time
	// Logger hears of a failed lookup, which avatar_variant_file_present? logs and counts as
	// present.
	Logger *slog.Logger

	lookups   singleflight.Group
	mu        sync.Mutex
	present   map[string]time.Time
	lastSweep time.Time
}

// webImageTypes is config.active_storage.web_image_content_types, with each type's Marcel
// extensions (Marcel::MimeType.for(extension:) matches them case-insensitively) and
// Marcel::Magic#extensions.first.
var webImageTypes = map[string]struct {
	extensions []string
	first      string
}{
	"image/png":  {[]string{"png"}, "png"},
	"image/jpeg": {[]string{"jpg", "jpeg", "jpe", "jif", "jfif", "jfi"}, "jpg"},
	"image/gif":  {[]string{"gif"}, "gif"},
}

// URL is User#avatar_url for userID.
func (a *Avatars) URL(ctx context.Context, userID int64) (string, error) {
	rows, err := a.DB.QueryContext(ctx, `SELECT active_storage_blobs.id, active_storage_blobs.filename, active_storage_blobs.content_type,
		active_storage_variant_records.variation_digest, variant_blobs.key
		FROM active_storage_attachments
		LEFT JOIN active_storage_blobs ON active_storage_blobs.id = active_storage_attachments.blob_id
		LEFT JOIN active_storage_variant_records ON active_storage_variant_records.blob_id = active_storage_blobs.id
		LEFT JOIN active_storage_attachments variant_images ON variant_images.record_type = 'ActiveStorage::VariantRecord'
			AND variant_images.record_id = active_storage_variant_records.id AND variant_images.name = 'image'
		LEFT JOIN active_storage_blobs variant_blobs ON variant_blobs.id = variant_images.blob_id
		WHERE active_storage_attachments.record_type = 'User' AND active_storage_attachments.record_id = ?
		AND active_storage_attachments.name = 'avatar'`, userID)
	if err != nil {
		return "", fmt.Errorf("%w: %v", ErrUnported, err)
	}
	defer rows.Close()
	attached := false
	var digest string
	var key sql.NullString
	for rows.Next() {
		var blobID sql.NullInt64
		var filename, contentType, variation, variantKey sql.NullString
		if err := rows.Scan(&blobID, &filename, &contentType, &variation, &variantKey); err != nil {
			return "", fmt.Errorf("%w: %v", ErrUnported, err)
		}
		if !blobID.Valid {
			// avatar.url raises without a blob, inside avatar_url's own rescue.
			return "", ErrUnported
		}
		if !attached {
			attached, digest = true, variationDigest(filename.String, contentType.String)
		}
		if variation.String == digest && variantKey.Valid {
			key = variantKey
		}
	}
	if err := rows.Err(); err != nil {
		// avatar_url rescues everything, so Rails would still answer.
		return "", fmt.Errorf("%w: %v", ErrUnported, err)
	}
	if !attached {
		return a.AssetHost + "/images/gumroad-default-avatar-5.png", nil
	}
	if !rails.Present(key.String) {
		// variant.processed would resize the upload and write the variant.
		return "", ErrUnported
	}
	if !a.variantPresent(ctx, key.String) {
		// stored_avatar_variant destroys the variant and resizes again.
		return "", ErrUnported
	}
	// The public service's url, through cdn_url_for.
	return a.PublicCDN + key.String, nil
}

// variantPresent is avatar_variant_file_present?: a file found within the TTL Rails' cache
// keeps one is present, and so is any whose lookup fails.
func (a *Avatars) variantPresent(ctx context.Context, key string) bool {
	now := a.Now()
	a.mu.Lock()
	seen, ok := a.present[key]
	a.mu.Unlock()
	if ok && now.Sub(seen) < presenceTTL {
		return true
	}
	v, _, _ := a.lookups.Do(key, func() (any, error) {
		exists, err := a.Exists.Exists(ctx, key)
		if err != nil {
			if a.Logger != nil {
				a.Logger.Warn("avatar variant lookup failed", "key", key, "error", err.Error())
			}
			return true, nil
		}
		a.remember(key, exists, now)
		return exists, nil
	})
	return v.(bool)
}

// remember keeps what a lookup found, dropping entries past the TTL once a TTL.
func (a *Avatars) remember(key string, exists bool, now time.Time) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.present == nil {
		a.present = map[string]time.Time{}
	}
	if now.Sub(a.lastSweep) >= presenceTTL {
		for k, at := range a.present {
			if now.Sub(at) >= presenceTTL {
				delete(a.present, k)
			}
		}
		a.lastSweep = now
	}
	if exists {
		a.present[key] = now
	} else {
		delete(a.present, key)
	}
}

// variationDigest is ActiveStorage::Variation#digest for avatar_variant's
// resize_to_limit: [400, 400].
func variationDigest(filename, contentType string) string {
	return VariantDigest(filename, contentType, 400, 400)
}

// VariantDigest is ActiveStorage::Variation#digest for blob.variant(resize_to_limit:
// [width, height]) after default_to(default_variant_transformations): SHA1 of
// Marshal.dump({format:, resize_to_limit: [width, height]}), Base64. A negative bound is nil.
func VariantDigest(filename, contentType string, width, height int) string {
	var b bytes.Buffer
	b.WriteString("\x04\x08{")
	marshalLong(&b, 2)
	marshalSymbol(&b, "format")
	if web, ok := webImageTypes[contentType]; ok {
		format := web.first
		if ext := strings.TrimPrefix(rails.FileExtname(filename), "."); ext != "" && matchesExtension(web.extensions, ext) {
			format = ext
		}
		// A UTF-8 String: its bytes, then the encoding ivar E => true. :E is the second symbol.
		b.WriteString(`I"`)
		marshalLong(&b, len(format))
		b.WriteString(format)
		marshalLong(&b, 1)
		marshalSymbol(&b, "E")
		b.WriteByte('T')
	} else {
		marshalSymbol(&b, "png")
	}
	marshalSymbol(&b, "resize_to_limit")
	b.WriteByte('[')
	marshalLong(&b, 2)
	for _, n := range []int{width, height} {
		if n < 0 {
			b.WriteByte('0')
			continue
		}
		b.WriteByte('i')
		marshalLong(&b, n)
	}
	sum := sha1.Sum(b.Bytes())
	return base64.StdEncoding.EncodeToString(sum[:])
}

// matchesExtension is Marcel's lookup of ext.downcase, which leaves non-ASCII letters for
// these all-ASCII tables to miss.
func matchesExtension(extensions []string, ext string) bool {
	lower := []byte(ext)
	for i, c := range lower {
		if c >= 'A' && c <= 'Z' {
			lower[i] = c + 32
		}
	}
	for _, e := range extensions {
		if e == string(lower) {
			return true
		}
	}
	return false
}

func marshalSymbol(b *bytes.Buffer, s string) {
	b.WriteByte(':')
	marshalLong(b, len(s))
	b.WriteString(s)
}

// marshalLong is Marshal's w_long for the non-negative values below 65,536 written here.
func marshalLong(b *bytes.Buffer, n int) {
	switch {
	case n == 0:
		b.WriteByte(0)
	case n < 123:
		b.WriteByte(byte(n + 5))
	case n < 256:
		b.WriteByte(1)
		b.WriteByte(byte(n))
	default:
		b.WriteByte(2)
		b.WriteByte(byte(n))
		b.WriteByte(byte(n >> 8))
	}
}
