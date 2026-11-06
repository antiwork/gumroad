package products

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"slices"
	"strconv"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/railscache"
	"github.com/antiwork/gumroad/go_web/internal/storage"
)

// AssetPreview::DEFAULT_DISPLAY_WIDTH and RETINA_DISPLAY_WIDTH.
const (
	coverDisplayWidth = 670
	coverRetinaWidth  = coverDisplayWidth * 3 / 2
)

// variableTypes is ActiveStorage.variable_content_types; anything else raises on variant.
var variableTypes = []string{"image/png", "image/gif", "image/jpeg", "image/tiff", "image/bmp", "image/vnd.adobe.photoshop",
	"image/vnd.microsoft.icon", "image/webp", "image/avif", "image/heic", "image/heif"}

// cover is one of display_asset_previews, an uploaded image (the shapes this port renders).
type cover struct {
	guid                 sql.NullString
	attachmentID         int64
	blobID               int64
	key, filename        string
	contentType          string
	width, height        *int64
	url, originalURL     string
	isImage, postProcess bool
}

// coverOrder is in_order's sort key, which leaves ties to MySQL.
type coverOrder struct {
	position  sql.NullInt64
	createdAt db.NullTime
}

// loadCovers is display_asset_previews with each image's URLs. Any other cover goes to
// Rails: an oEmbed or Unsplash one, a video (whose poster Rails may enqueue), or an image
// whose retina variant isn't processed yet (url_from_file enqueues it).
func (h *handler) loadCovers(ctx context.Context, p *page, productID int64) ([]*cover, error) {
	// One row per attachment, through the attachments' unique index; a preview on two rows
	// has more than one file.
	rows, err := h.c.DB.QueryContext(ctx, `SELECT asset_previews.id, asset_previews.guid, asset_previews.position,
		asset_previews.created_at, asset_previews.unsplash_url, asset_previews.oembed IS NOT NULL, att.id, blobs.id, blobs.key,
		blobs.filename, blobs.content_type, blobs.metadata
		FROM asset_previews
		LEFT JOIN active_storage_attachments att ON att.record_type = 'AssetPreview' AND att.record_id = asset_previews.id
			AND att.name = 'file'
		LEFT JOIN active_storage_blobs blobs ON blobs.id = att.blob_id
		WHERE asset_previews.link_id = ? AND asset_previews.deleted_at IS NULL
		ORDER BY asset_previews.position ASC, asset_previews.created_at ASC, asset_previews.id ASC`, productID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var covers []*cover
	var keys []coverOrder
	var lastPreviewID int64
	for rows.Next() {
		var c cover
		var k coverOrder
		var previewID int64
		var unsplash, key, filename, contentType, metadata sql.NullString
		var hasOembed bool
		var attID, blobID sql.NullInt64
		if err := rows.Scan(&previewID, &c.guid, &k.position, &k.createdAt, &unsplash, &hasOembed, &attID, &blobID, &key,
			&filename, &contentType, &metadata); err != nil {
			return nil, err
		}
		switch {
		case unsplash.Valid:
			return nil, fallback("unsplash cover")
		case hasOembed:
			return nil, fallback("oembed cover")
		case !attID.Valid:
			return nil, fallback("cover without a file")
		case previewID == lastPreviewID || !blobID.Valid:
			return nil, fallback("cover attachment")
		}
		lastPreviewID = previewID
		c.attachmentID, c.blobID, c.key, c.filename, c.contentType = attID.Int64, blobID.Int64, key.String, filename.String, contentType.String
		if c.isImage = strings.HasPrefix(c.contentType, "image"); !c.isImage {
			return nil, fallback("video cover")
		}
		if c.width, c.height, err = blobDimensions(metadata.String); err != nil {
			return nil, fallback("cover metadata")
		}
		c.postProcess = !strings.Contains(c.contentType, "gif")
		covers = append(covers, &c)
		keys = append(keys, k)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for i := 1; i < len(keys); i++ {
		// in_order leaves ties to MySQL.
		if keys[i] == keys[i-1] {
			return nil, fallback("cover order")
		}
	}
	for _, c := range covers {
		if err := h.coverURLs(ctx, p, c); err != nil {
			return nil, err
		}
	}
	return covers, nil
}

// blobDimensions reads the analyzer's width and height out of the blob's metadata.
func blobDimensions(metadata string) (width, height *int64, err error) {
	if strings.TrimSpace(metadata) == "" {
		return nil, nil, nil
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal([]byte(metadata), &m); err != nil {
		return nil, nil, err
	}
	read := func(name string) (*int64, error) {
		raw, ok := m[name]
		if !ok || string(raw) == "null" {
			return nil, nil
		}
		var n json.Number
		if err := json.Unmarshal(raw, &n); err != nil {
			return nil, err
		}
		v, err := n.Int64()
		if err != nil {
			return nil, err
		}
		return &v, nil
	}
	if width, err = read("width"); err != nil {
		return nil, nil, err
	}
	height, err = read("height")
	return width, height, err
}

// coverURLs is url and url(style: :original), through cdn_url_for.
func (h *handler) coverURLs(ctx context.Context, p *page, c *cover) error {
	original, err := h.originalCoverURL(ctx, p, c)
	if err != nil {
		return err
	}
	c.originalURL = original
	if !c.postProcess {
		c.url = original
		return nil
	}
	c.url, err = h.retinaCoverURL(ctx, p, c)
	return err
}

func (h *handler) originalCoverURL(ctx context.Context, p *page, c *cover) (string, error) {
	pc := h.c.Page
	original, err := h.cachedURL(ctx, p, "attachment_"+itoa(c.attachmentID)+"_original_url", pc.PublicStorageURL+c.key)
	return pc.cdnURL(original), err
}

// retinaCoverURL is url_from_file(style: :retina) for a processed variant.
func (h *handler) retinaCoverURL(ctx context.Context, p *page, c *cover) (string, error) {
	pc := h.c.Page
	if !slices.Contains(variableTypes, c.contentType) {
		// retina_variant raises, and url_from_file's rescue answers file.url.
		return "", fallback("invariable cover")
	}
	retina := coverRetinaWidth
	if c.width == nil {
		return "", fallback("cover width")
	}
	if *c.width < int64(retina) {
		retina = int(*c.width)
	}
	digest := storage.VariantDigest(c.filename, c.contentType, retina, -1)
	var variantKey sql.NullString
	err := h.c.DB.QueryRowContext(ctx, `SELECT variant_blobs.key FROM active_storage_variant_records
		LEFT JOIN active_storage_attachments variant_images ON variant_images.record_type = 'ActiveStorage::VariantRecord'
			AND variant_images.record_id = active_storage_variant_records.id AND variant_images.name = 'image'
		LEFT JOIN active_storage_blobs variant_blobs ON variant_blobs.id = variant_images.blob_id
		WHERE active_storage_variant_records.blob_id = ? AND active_storage_variant_records.variation_digest = ? LIMIT 1`,
		c.blobID, digest).Scan(&variantKey)
	if errors.Is(err, sql.ErrNoRows) {
		return "", fallback("retina variant unprocessed")
	}
	if err != nil {
		return "", err
	}
	if !variantKey.Valid {
		return "", fallback("retina variant image")
	}
	retinaURL, err := h.cachedURL(ctx, p, "attachment_"+itoa(c.attachmentID)+"_retina_url", pc.PublicStorageURL+variantKey.String)
	return pc.cdnURL(retinaURL), err
}

// cachedURL is Rails.cache.fetch(key) { computed } for a URL string: the cached value, or
// computed, written as Rails writes it (except in a dry run).
func (h *handler) cachedURL(ctx context.Context, p *page, key, computed string) (string, error) {
	v, found, err := h.readCache(ctx, key)
	switch {
	case err != nil:
		return "", err
	case found:
		s, ok := v.(string)
		if !ok {
			return "", fallback("cached url")
		}
		return s, nil
	}
	p.cacheWrites = append(p.cacheWrites, pendingWrite{key, computed, 0})
	return computed, nil
}

// json is AssetPreview#as_json.
func (c *cover) json() *rails.RHash {
	var width, height, nativeWidth, nativeHeight any
	if c.width != nil {
		nativeWidth = *c.width
		if *c.width > 0 {
			dw := min(int64(coverDisplayWidth), *c.width)
			width = dw
			if c.height != nil {
				height = int64(float64(*c.height) * (float64(dw) / float64(*c.width)))
			}
		}
	}
	if c.height != nil {
		nativeHeight = *c.height
	}
	return rails.NewRHash().
		Sym("url", c.url).
		Sym("original_url", c.originalURL).
		Sym("thumbnail", nil).
		Sym("id", nullString(c.guid)).
		Sym("type", "image").
		Sym("filetype", c.filetype()).
		Sym("width", width).
		Sym("height", height).
		Sym("native_width", nativeWidth).
		Sym("native_height", nativeHeight)
}

// filetype is the filename's extension without its dot, else the content type's subtype.
func (c *cover) filetype() any {
	if ext := strings.Replace(rails.FileExtname(c.filename), ".", "", 1); ext != "" {
		return ext
	}
	parts := rails.Split(c.contentType, "/")
	if len(parts) == 0 {
		return nil
	}
	return parts[len(parts)-1]
}

func nullInt(n sql.NullInt64) any {
	if !n.Valid {
		return nil
	}
	return n.Int64
}

func nullString(s sql.NullString) any {
	if !s.Valid {
		return nil
	}
	return s.String
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

// readCache is Rails.cache.read; an entry this port can't read, or a server down, is Rails'.
func (h *handler) readCache(ctx context.Context, key string) (any, bool, error) {
	v, found, err := h.c.Page.Cache.Read(ctx, key)
	if errors.Is(err, railscache.ErrUnported) || errors.Is(err, railscache.ErrServerDown) {
		return nil, false, fallback("cache")
	}
	return v, found, err
}
