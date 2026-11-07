// Package storage builds the Active Storage URLs Rails pages show: a user's avatar.
package storage

import (
	"context"
	"crypto/sha1"
	"database/sql"
	"encoding/base64"
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"strings"
	"sync"
	"time"

	"golang.org/x/sync/singleflight"

	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/railscache"
)

// ErrUnported is an avatar whose URL only Rails can give.
var ErrUnported = errors.New("an avatar URL this port leaves to Rails")

// variableTypes is ActiveStorage.variable_content_types; anything else raises on variant.
var variableTypes = []string{"image/png", "image/gif", "image/jpeg", "image/tiff", "image/bmp", "image/vnd.adobe.photoshop",
	"image/vnd.microsoft.icon", "image/webp", "image/avif", "image/heic", "image/heif"}

// Variable is blob.variable?.
func Variable(contentType string) bool { return slices.Contains(variableTypes, contentType) }

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
	// AssetHost is config.asset_host, PublicStorage the public service's object URL prefix,
	// and PublicCDN what CDN_URL_MAP turns that prefix into.
	AssetHost, PublicStorage, PublicCDN string
	Now                                 func() time.Time
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

// URL is User#avatar_url for userID. resize is its generate_avatar_variant_later: the
// variant or its file is missing, so the URL is the upload's own.
func (a *Avatars) URL(ctx context.Context, userID int64) (url string, resize bool, err error) {
	rows, err := a.DB.QueryContext(ctx, `SELECT active_storage_blobs.id, active_storage_blobs.key, active_storage_blobs.filename, active_storage_blobs.content_type,
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
		return "", false, fmt.Errorf("%w: %v", ErrUnported, err)
	}
	defer rows.Close()
	attached := false
	var digest, original, contentType string
	var key sql.NullString
	for rows.Next() {
		var blobID sql.NullInt64
		var blobKey, filename, blobType, variation, variantKey sql.NullString
		if err := rows.Scan(&blobID, &blobKey, &filename, &blobType, &variation, &variantKey); err != nil {
			return "", false, fmt.Errorf("%w: %v", ErrUnported, err)
		}
		if !blobID.Valid {
			// avatar.url raises without a blob, inside avatar_url's own rescue.
			return "", false, ErrUnported
		}
		if !attached {
			attached, original, contentType = true, blobKey.String, blobType.String
			digest = variationDigest(filename.String, contentType)
		}
		if variation.String == digest && variantKey.Valid {
			key = variantKey
		}
	}
	if err := rows.Err(); err != nil {
		// avatar_url rescues everything, so Rails would still answer.
		return "", false, fmt.Errorf("%w: %v", ErrUnported, err)
	}
	if !attached {
		return a.AssetHost + "/images/gumroad-default-avatar-5.png", false, nil
	}
	// avatar.url, the public service's, which avatar_url serves without cdn_url_for.
	original = a.PublicStorage + original
	if !Variable(contentType) {
		// avatar.variant raises, and avatar_url's rescue answers avatar.url.
		return original, false, nil
	}
	if !rails.Present(key.String) || !a.variantPresent(ctx, key.String) {
		return original, true, nil
	}
	// The public service's url, through cdn_url_for.
	return a.PublicCDN + key.String, false, nil
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
// Marshal.dump({format:, resize_to_limit: [width, height]}), Base64. Each bound is an integer,
// a float64 or nil, as Ruby holds it; anything else panics.
func VariantDigest(filename, contentType string, width, height any) string {
	var format any = railscache.Symbol("png")
	if web, ok := webImageTypes[contentType]; ok {
		format = web.first
		if ext := strings.TrimPrefix(rails.FileExtname(filename), "."); ext != "" && matchesExtension(web.extensions, ext) {
			format = ext
		}
	}
	data, err := railscache.Dump(railscache.Hash{
		{Key: railscache.Symbol("format"), Value: format},
		{Key: railscache.Symbol("resize_to_limit"), Value: []any{width, height}},
	})
	if err != nil {
		// Only a non-UTF-8 symbol or an unsupported type fails, and these are neither.
		panic(err)
	}
	sum := sha1.Sum(data)
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
