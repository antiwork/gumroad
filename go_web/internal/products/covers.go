package products

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"go.yaml.in/yaml/v3"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/html4"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/railscache"
	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
	"github.com/antiwork/gumroad/go_web/internal/storage"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

// maxDimension keeps a width or height where Ruby's and Go's to_i and Float arithmetic agree;
// no image or video comes near it.
const maxDimension = 1 << 40

// AssetPreview::DEFAULT_DISPLAY_WIDTH and RETINA_DISPLAY_WIDTH.
const (
	coverDisplayWidth = 670
	coverRetinaWidth  = coverDisplayWidth * 3 / 2
)

// cover is one of display_asset_previews: an uploaded image or video, or an embedded player.
type cover struct {
	guid                          sql.NullString
	previewID, attachmentID       int64
	blobID                        int64
	key, filename                 string
	contentType                   string
	width, height                 *dimension
	url, originalURL              string
	isImage, isVideo, postProcess bool
	isUnsplash                    bool
	// retinaRead is url read through the retina variant's cache entry, not the original's, and
	// rescued one url_from_file's rescue answered without either.
	retinaRead, rescued bool
	// oembed is an embedded player's column, as OEmbedFinder stores it.
	oembed *oembedData
	// thumbnail is thumbnail_url: a video's poster or a player's thumbnail; "" is nil.
	thumbnail string
}

// dimension is a blob metadata width or height as JSON loads it: an Integer, or a Float from
// the video analyzer.
type dimension struct {
	n     float64
	float bool
}

// value is the Ruby number.
func (d dimension) value() any {
	if d.float {
		return d.n
	}
	return int64(d.n)
}

func (d dimension) toI() int64 { return int64(d.n) }

// newDimension is a width or height within maxDimension.
func newDimension(n float64, float bool) (*dimension, bool) {
	if n > maxDimension || n < -maxDimension {
		return nil, false
	}
	return &dimension{n: n, float: float}, true
}

// minWith is [limit, d].min, which keeps limit unless d is strictly smaller.
func (d dimension) minWith(limit int64) dimension {
	if d.n < float64(limit) {
		return d
	}
	return dimension{n: float64(limit)}
}

// coverOrder is in_order's sort key, which leaves ties to MySQL.
type coverOrder struct {
	position  sql.NullInt64
	createdAt db.NullTime
}

// loadCovers is display_asset_previews with each one's URLs.
func (h *handler) loadCovers(ctx context.Context, p *page, productID int64) ([]*cover, error) {
	covers, err := h.loadCoverRows(ctx, productID)
	if err != nil {
		return nil, err
	}
	for _, c := range covers {
		if err := h.coverURLs(ctx, p, c); err != nil {
			return nil, err
		}
	}
	return covers, nil
}

// loadCoverRows is display_asset_previews without their URLs. Any other cover goes to Rails:
// an Unsplash one with a file or player, or a video without a persisted poster (Rails may enqueue one).
func (h *handler) loadCoverRows(ctx context.Context, productID int64) ([]*cover, error) {
	// One row per attachment, through the attachments' unique index; a preview on two rows
	// has more than one file.
	rows, err := h.c.DB.QueryContext(ctx, `SELECT asset_previews.id, asset_previews.guid, asset_previews.position,
		asset_previews.created_at, asset_previews.unsplash_url, asset_previews.oembed, att.id, blobs.id, blobs.key,
		blobs.filename, blobs.content_type, blobs.metadata
		FROM asset_previews
		LEFT JOIN active_storage_attachments att ON att.record_type = 'AssetPreview' AND att.record_id = asset_previews.id
			AND att.name = 'file'
		LEFT JOIN active_storage_blobs blobs ON blobs.id = att.blob_id
		WHERE asset_previews.link_id = ? AND asset_previews.deleted_at IS NULL
		ORDER BY asset_previews.position ASC, asset_previews.created_at ASC, asset_previews.id ASC, att.blob_id ASC`, productID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var covers []*cover
	var keys []coverOrder
	var ids []int64
	var lastPreviewID int64
	for rows.Next() {
		var c cover
		var k coverOrder
		var previewID int64
		var unsplash, oembed, key, filename, contentType, metadata sql.NullString
		var attID, blobID sql.NullInt64
		if err := rows.Scan(&previewID, &c.guid, &k.position, &k.createdAt, &unsplash, &oembed, &attID, &blobID, &key,
			&filename, &contentType, &metadata); err != nil {
			return nil, err
		}
		switch {
		case unsplash.Valid:
			// url answers the Unsplash URL when present; width and height read the file or oembed.
			if !rails.Present(unsplash.String) || oembed.Valid || attID.Valid {
				return nil, fallback("unsplash cover")
			}
			c.isUnsplash, c.url, c.originalURL = true, unsplash.String, unsplash.String
		case oembed.Valid && attID.Valid:
			return nil, fallback("oembed cover with a file")
		case oembed.Valid:
			// Without a file, the join gives the preview one row.
			if c.oembed, err = parseOembed(oembed.String); err != nil {
				return nil, err
			}
			var okW, okH bool
			c.width, okW = newDimension(float64(c.oembed.Info.Width), false)
			c.height, okH = newDimension(float64(c.oembed.Info.Height), false)
			if !okW || !okH {
				return nil, fallback("oembed size")
			}
		case !attID.Valid:
			return nil, fallback("cover without a file")
		case previewID == lastPreviewID:
			// has_one's query reads the attachments' unique index, so the lowest blob_id wins.
			continue
		case !blobID.Valid:
			return nil, fallback("cover attachment")
		default:
			lastPreviewID = previewID
			c.previewID, c.attachmentID, c.blobID, c.key, c.filename, c.contentType = previewID, attID.Int64, blobID.Int64, key.String, filename.String, contentType.String
			// display_type, and should_post_process? for an image.
			switch {
			case strings.HasPrefix(c.contentType, "image"):
				c.isImage, c.postProcess = true, !strings.Contains(c.contentType, "gif")
			case strings.HasPrefix(c.contentType, "video"):
				c.isVideo = true
			default:
				return nil, fallback("cover type")
			}
			if c.width, c.height, err = blobDimensions(metadata.String); err != nil {
				return nil, fallback("cover metadata")
			}
		}
		covers = append(covers, &c)
		keys = append(keys, k)
		ids = append(ids, previewID)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for i := 1; i < len(keys); i++ {
		if keys[i] == keys[i-1] {
			// in_order leaves ties to MySQL, so each of Rails' statements has to agree with this
			// order, which breaks them by id.
			same, err := h.railsCoverOrder(ctx, productID, ids)
			if err != nil {
				return nil, err
			}
			if !same {
				return nil, fallback("cover order")
			}
			break
		}
	}
	return covers, nil
}

// railsCoverOrder is whether Rails' display_asset_previews statements return the previews in
// want's order: the association's, its preload's, and first's LIMIT 1.
func (h *handler) railsCoverOrder(ctx context.Context, productID int64, want []int64) (bool, error) {
	const order = " ORDER BY `asset_previews`.`position` ASC, `asset_previews`.`created_at` ASC"
	for _, s := range []struct {
		query string
		first bool
	}{
		{"SELECT `asset_previews`.* FROM `asset_previews` WHERE `asset_previews`.`link_id` = ? AND `asset_previews`.`deleted_at` IS NULL" + order, false},
		{"SELECT `asset_previews`.* FROM `asset_previews` WHERE `asset_previews`.`deleted_at` IS NULL AND `asset_previews`.`link_id` = ?" + order, false},
		{"SELECT `asset_previews`.* FROM `asset_previews` WHERE `asset_previews`.`link_id` = ? AND `asset_previews`.`deleted_at` IS NULL" + order + " LIMIT 1", true},
	} {
		ids, err := h.scanIDs(ctx, s.query, productID)
		if err != nil {
			return false, err
		}
		expected := want
		if s.first {
			expected = want[:1]
		}
		if !slices.Equal(ids, expected) {
			return false, nil
		}
	}
	return true, nil
}

// blobDimensions reads the analyzer's width and height out of the blob's metadata.
func blobDimensions(metadata string) (width, height *dimension, err error) {
	if strings.TrimSpace(metadata) == "" {
		return nil, nil, nil
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal([]byte(metadata), &m); err != nil {
		return nil, nil, err
	}
	read := func(name string) (*dimension, error) {
		raw, ok := m[name]
		if !ok || string(raw) == "null" {
			return nil, nil
		}
		var n json.Number
		// json.Number also takes a quoted number, which Ruby keeps a String.
		if raw[0] == '"' || json.Unmarshal(raw, &n) != nil {
			return nil, errors.New("dimension is not a number")
		}
		float := strings.ContainsAny(string(n), ".eE")
		f, err := n.Float64()
		d, ok := newDimension(f, float)
		if err != nil || !ok || !float && float64(int64(f)) != f {
			return nil, errors.New("dimension out of range")
		}
		return d, nil
	}
	if width, err = read("width"); err != nil {
		return nil, nil, err
	}
	height, err = read("height")
	return width, height, err
}

// coverURLs is url and url(style: :original), through cdn_url_for, and thumbnail_url.
func (h *handler) coverURLs(ctx context.Context, p *page, c *cover) error {
	if c.isUnsplash {
		return nil
	}
	if o := c.oembed; o != nil {
		url, err := o.url()
		if err != nil {
			return err
		}
		c.url, c.originalURL = url, url
		if thumbnail, ok := o.thumbnailURL(); ok {
			c.thumbnail = thumbnail
		}
		return nil
	}
	original, err := h.originalCoverURL(ctx, p, c)
	if err != nil {
		return err
	}
	c.originalURL = original
	if c.isVideo {
		c.url = original
		c.thumbnail, err = h.videoPosterURL(ctx, p, c)
		return err
	}
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

// retinaVariantJob is ProcessAssetPreviewRetinaWorker's sidekiq_options.
var retinaVariantJob = sidekiq.Options{Class: "ProcessAssetPreviewRetinaWorker", Queue: "low", Retry: 3}

// pushVariants is enqueue_retina_variant_process for each cover whose URL the page read,
// video_poster_url's GenerateVideoPosterWorker for each poster it lacked, and
// generate_avatar_variant_later for each avatar.
func (h *handler) pushVariants(ctx context.Context, p *page) error {
	jobs := h.c.Page.Sidekiq
	for _, id := range p.retinaPushes {
		if _, _, err := jobs.PushUntilExecuted(context.WithoutCancel(ctx), retinaVariantJob, id); err != nil {
			web.Logger(p.Req.HTTP).Warn("retina variant push failed", "error", err.Error())
			return fallback("retina variant push")
		}
	}
	for _, id := range p.posterPushes {
		if _, _, err := jobs.PushUntilExecuted(context.WithoutCancel(ctx), videoPosterJob, id); err != nil {
			web.Logger(p.Req.HTTP).Warn("video poster push failed", "error", err.Error())
			return fallback("video poster push")
		}
	}
	for _, id := range p.avatarPushes {
		if _, _, err := jobs.PushUntilExecuting(context.WithoutCancel(ctx), avatarVariantJob, id); err != nil {
			web.Logger(p.Req.HTTP).Warn("avatar variant push failed", "error", err.Error())
			return fallback("avatar variant push")
		}
	}
	return nil
}

// retinaCoverURL is url_from_file(style: :retina). An unprocessed variant enqueues its
// processing, which the page pushes once it renders, and serves the original meanwhile.
func (h *handler) retinaCoverURL(ctx context.Context, p *page, c *cover) (string, error) {
	pc := h.c.Page
	if !storage.Variable(c.contentType) {
		// retina_variant raises, and url_from_file's rescue answers file.url, uncached.
		c.rescued = true
		return pc.cdnURL(pc.PublicStorageURL + c.key), nil
	}
	// retina_width is nil for a blob the analyzer never measured, so the variant is
	// resize_to_limit [nil, nil].
	var width any
	if c.width != nil {
		width = c.width.minWith(coverRetinaWidth).value()
	}
	digest := storage.VariantDigest(c.filename, c.contentType, width, nil)
	variantKey, found, err := h.variantKey(ctx, c.blobID, digest)
	if err != nil {
		return "", err
	}
	if !found {
		if h.c.Page.Sidekiq == nil {
			return "", fallback("retina variant push")
		}
		p.retinaPushes = appendNew(p.retinaPushes, c.previewID)
		if c.originalURL != "" {
			return c.originalURL, nil
		}
		return h.originalCoverURL(ctx, p, c)
	}
	if !variantKey.Valid {
		return "", fallback("retina variant image")
	}
	c.retinaRead = true
	retinaURL, err := h.cachedURL(ctx, p, "attachment_"+itoa(c.attachmentID)+"_retina_url", pc.PublicStorageURL+variantKey.String)
	return pc.cdnURL(retinaURL), err
}

// variantKey is the image key of the blob's variant record for digest; found is false without
// a record, and the key is NULL for a record without its image.
func (h *handler) variantKey(ctx context.Context, blobID int64, digest string) (sql.NullString, bool, error) {
	var key sql.NullString
	err := h.c.DB.QueryRowContext(ctx, `SELECT variant_blobs.key FROM active_storage_variant_records
		LEFT JOIN active_storage_attachments variant_images ON variant_images.record_type = 'ActiveStorage::VariantRecord'
			AND variant_images.record_id = active_storage_variant_records.id AND variant_images.name = 'image'
		LEFT JOIN active_storage_blobs variant_blobs ON variant_blobs.id = variant_images.blob_id
		WHERE active_storage_variant_records.blob_id = ? AND active_storage_variant_records.variation_digest = ? LIMIT 1`,
		blobID, digest).Scan(&key)
	if errors.Is(err, sql.ErrNoRows) {
		return key, false, nil
	}
	return key, err == nil, err
}

// videoPosterJob is GenerateVideoPosterWorker's sidekiq_options.
var videoPosterJob = sidekiq.Options{Class: "GenerateVideoPosterWorker", Queue: "low", Retry: 3}

// videoPosterURL is video_poster_url for a video ActiveStorage can preview (ffmpeg is on Rails'
// hosts): the cached poster, else the persisted one, else none, enqueueing
// GenerateVideoPosterWorker unless a failure sentinel is cached.
func (h *handler) videoPosterURL(ctx context.Context, p *page, c *cover) (string, error) {
	key := "attachment_" + itoa(c.attachmentID) + "_poster_url"
	cached, found, err := h.readCache(ctx, key)
	if err != nil {
		return "", err
	}
	if found {
		s, ok := cached.(string)
		if !ok {
			return "", fallback("cached poster")
		}
		if rails.Present(s) {
			return s, nil
		}
	}
	persisted, err := h.persistedPosterURL(ctx, c)
	if err != nil {
		return "", err
	}
	if persisted != "" {
		p.cacheWrites = append(p.cacheWrites, pendingWrite{key, persisted, 0})
		return persisted, nil
	}
	if found {
		return "", nil
	}
	if h.c.Page.Sidekiq == nil {
		return "", fallback("video poster push")
	}
	p.posterPushes = appendNew(p.posterPushes, c.previewID)
	return "", nil
}

// persistedPosterURL is persisted_video_poster_url: the blob's preview image resized to
// retina_width, when that variant exists; "" otherwise.
func (h *handler) persistedPosterURL(ctx context.Context, c *cover) (string, error) {
	// blob.preview_image's has_one statement, verbatim: it has no ORDER BY, so among duplicate
	// attachments MySQL's plan picks the row, and the same text gets the same plan.
	var attached sql.NullInt64
	if err := scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
		cols["blob_id"] = &attached
		return func() {}
	}, "SELECT `active_storage_attachments`.* FROM `active_storage_attachments` WHERE `active_storage_attachments`.`record_id` = ?"+
		" AND `active_storage_attachments`.`record_type` = 'ActiveStorage::Blob' AND `active_storage_attachments`.`name` = 'preview_image' LIMIT 1",
		c.blobID); err != nil || !attached.Valid {
		return "", err
	}
	var preview struct {
		id                    int64
		filename, contentType sql.NullString
	}
	// The attachments' foreign key keeps the blob.
	if err := h.c.DB.QueryRowContext(ctx, "SELECT active_storage_blobs.id, active_storage_blobs.filename, active_storage_blobs.content_type"+
		" FROM active_storage_blobs WHERE active_storage_blobs.id = ? LIMIT 1", attached.Int64).Scan(&preview.id, &preview.filename, &preview.contentType); err != nil {
		return "", err
	}
	width := any(int64(coverRetinaWidth))
	if c.width != nil {
		width = c.width.minWith(coverRetinaWidth).value()
	}
	digest := storage.VariantDigest(preview.filename.String, preview.contentType.String, width, nil)
	variantKey, found, err := h.variantKey(ctx, preview.id, digest)
	if err != nil || !found {
		return "", err
	}
	if !variantKey.Valid {
		// variant.processed would process a record without its image.
		return "", fallback("poster variant image")
	}
	pc := h.c.Page
	return pc.cdnURL(pc.PublicStorageURL + variantKey.String), nil
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
		nativeWidth = c.width.value()
	}
	if c.height != nil {
		nativeHeight = c.height.value()
	}
	if dw, ok := c.displayWidth(); ok {
		width = dw.value()
	}
	if dh, ok := c.displayHeight(); ok {
		height = dh
	}
	typ := "image"
	switch {
	case c.isUnsplash:
		typ = "unsplash"
	case c.oembed != nil:
		typ = "oembed"
	case c.isVideo:
		typ = "video"
	}
	return rails.NewRHash().
		Sym("url", c.url).
		Sym("original_url", c.originalURL).
		Sym("thumbnail", presence(c.thumbnail)).
		Sym("id", nullString(c.guid)).
		Sym("type", typ).
		Sym("filetype", c.filetype()).
		Sym("width", width).
		Sym("height", height).
		Sym("native_width", nativeWidth).
		Sym("native_height", nativeHeight)
}

// displayWidth is display_width, false where it's nil.
func (c *cover) displayWidth() (dimension, bool) {
	if c.width == nil || c.width.toI() <= 0 {
		return dimension{}, false
	}
	return c.width.minWith(coverDisplayWidth), true
}

// displayHeight is display_height, false where it's nil.
func (c *cover) displayHeight() (int64, bool) {
	dw, ok := c.displayWidth()
	if !ok || c.height == nil {
		return 0, false
	}
	return int64(float64(c.height.toI()) * (float64(dw.toI()) / c.width.n)), true
}

// previewImagePath is preview_image_path? for the main cover: an image file or an Unsplash photo.
func (c *cover) previewImagePath() bool { return c.isImage || c.isUnsplash }

// urlCacheKey is the Rails.cache entry url_from_file read for c's url, the retina variant's or the
// original's; "" for an Unsplash URL or one url_from_file's rescue answered.
func (c *cover) urlCacheKey() string {
	switch {
	case c.isUnsplash || c.rescued:
		return ""
	case c.retinaRead:
		return "attachment_" + itoa(c.attachmentID) + "_retina_url"
	}
	return "attachment_" + itoa(c.attachmentID) + "_original_url"
}

// filenameSanitizer is the tr in ActiveStorage::Filename#sanitized.
var filenameSanitizer = strings.NewReplacer("\u202E", "-", "%", "-", "$", "-", "|", "-", ":", "-", ";", "-", "/", "-", "<", "-",
	">", "-", "?", "-", "*", "-", `"`, "-", "\t", "-", "\r", "-", "\n", "-", `\`, "-")

// sanitizedFilename is ActiveStorage::Filename#to_s. A blob uploaded from a URL keeps its query
// string, whose ? and % this rewrites.
func sanitizedFilename(name string) string { return filenameSanitizer.Replace(rails.Strip(name)) }

// filetype is AssetPreview#filetype.
func (c *cover) filetype() any {
	if c.oembed != nil || c.isUnsplash {
		return nil
	}
	if ext := strings.Replace(rails.FileExtname(sanitizedFilename(c.filename)), ".", "", 1); ext != "" {
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

// oembedData is an asset preview's oembed column as OEmbedFinder stores it. Width and height
// stand for their to_i, nil being 0.
type oembedData struct {
	HTML string `yaml:"html"`
	Info *struct {
		ThumbnailURL *string `yaml:"thumbnail_url"`
		Width        int64   `yaml:"width"`
		Height       int64   `yaml:"height"`
	} `yaml:"info"`
}

// parseOembed loads the column as its YAML coder does, for the plain Hash OEmbedFinder writes.
// A tag, an anchor or any other shape goes to Rails.
func parseOembed(raw string) (*oembedData, error) {
	var doc yaml.Node
	if yaml.Unmarshal([]byte(raw), &doc) != nil || !plainYAML(&doc) {
		return nil, fallback("oembed yaml")
	}
	var o oembedData
	dec := yaml.NewDecoder(strings.NewReader(raw))
	dec.KnownFields(true)
	if dec.Decode(&o) != nil || o.Info == nil {
		return nil, fallback("oembed yaml")
	}
	return &o, nil
}

// plainYAML is a document of maps, strings, decimal integers and nulls only, which Psych and
// this decoder read alike: a plain 0o17 is a String to Psych but an int here.
func plainYAML(n *yaml.Node) bool {
	if n.Anchor != "" {
		return false
	}
	switch n.Kind {
	case yaml.DocumentNode:
	case yaml.MappingNode:
		if n.Tag != "!!map" {
			return false
		}
	case yaml.ScalarNode:
		if n.Tag != "!!str" && n.Tag != "!!null" && !(n.Tag == "!!int" && decimalInt.MatchString(n.Value)) {
			return false
		}
	default:
		return false
	}
	for _, c := range n.Content {
		if !plainYAML(c) {
			return false
		}
	}
	return true
}

var (
	decimalInt    = regexp.MustCompile(`\A-?(?:0|[1-9][0-9]*)\z`)
	unsafeURL     = regexp.MustCompile(`(?i)\A[ \t\r\n\f\v]*(?:javascript|data|vbscript|file):`)
	youtubeOembed = regexp.MustCompile(`youtube.*feature=oembed`)
	vimeoVideo    = regexp.MustCompile(`vimeo.com/video/\d+\z`)
)

// safeURL is AssetPreview#safe_url?.
func safeURL(url string) bool { return rails.Present(url) && !unsafeURL.MatchString(url) }

// url is oembed_url: the first iframe's src, made absolute, with the players' API flags.
func (o *oembedData) url() (string, error) {
	frag, err := html4.ParseFragment(o.HTML)
	if err != nil {
		return "", fallback("oembed html")
	}
	iframe := firstElement(frag, "iframe")
	if iframe == nil {
		return "", fallback("oembed without an iframe")
	}
	src, ok := iframe.Attr("src")
	if !ok {
		// iframe[:src].strip raises.
		return "", fallback("oembed iframe src")
	}
	url := rails.Strip(src)
	if !safeURL(url) {
		return "", fallback("oembed url")
	}
	if strings.HasPrefix(url, "//") {
		url = "https:" + url
	}
	if youtubeOembed.MatchString(url) {
		url += "&enablejsapi=1"
	}
	if vimeoVideo.MatchString(url) {
		url += "?api=1"
	}
	return url, nil
}

// thumbnailURL is oembed_thumbnail_url.
func (o *oembedData) thumbnailURL() (string, bool) {
	var url string
	if o.Info.ThumbnailURL != nil {
		url = rails.Strip(*o.Info.ThumbnailURL)
	}
	return url, safeURL(url)
}

// firstElement is css(name).first: the first such element in document order.
func firstElement(n *html4.Node, name string) *html4.Node {
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		if c.Type == html4.ElementNode && c.Name == name {
			return c
		}
		if found := firstElement(c, name); found != nil {
			return found
		}
	}
	return nil
}
