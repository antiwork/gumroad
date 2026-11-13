package delivery

import (
	"database/sql"
	"regexp"
	"strconv"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/storage"
)

// supportedThumbnailType is ProductFile::SUPPORTED_THUMBNAIL_IMAGE_CONTENT_TYPES.
var supportedThumbnailType = regexp.MustCompile(`(?i)jpeg|gif|png|jpg`)

// thumbnail is a product file's thumbnail attachment, with its blob when the row exists.
type thumbnail struct {
	attachmentID               int64
	blobID                     sql.NullInt64
	key, contentType, filename sql.NullString
}

// loadThumbnails is each file's thumbnail attachment. has_one reads one row without an order,
// so a file with two is left to Rails.
func loadThumbnails(l *loader, ids []any) (map[int64]*thumbnail, error) {
	rows, err := l.conn.QueryContext(l.ctx, "SELECT active_storage_attachments.record_id, active_storage_attachments.id,"+
		" active_storage_blobs.id, active_storage_blobs.key, active_storage_blobs.content_type, active_storage_blobs.filename"+
		" FROM active_storage_attachments LEFT JOIN active_storage_blobs ON active_storage_blobs.id = active_storage_attachments.blob_id"+
		" WHERE active_storage_attachments.record_type = 'ProductFile' AND active_storage_attachments.name = 'thumbnail'"+
		" AND active_storage_attachments.record_id IN ("+placeholders(len(ids))+")", ids...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	thumbnails := map[int64]*thumbnail{}
	for rows.Next() {
		var fileID int64
		t := &thumbnail{}
		if err := rows.Scan(&fileID, &t.attachmentID, &t.blobID, &t.key, &t.contentType, &t.filename); err != nil {
			return nil, err
		}
		if thumbnails[fileID] != nil {
			return nil, ErrUnported
		}
		thumbnails[fileID] = t
	}
	return thumbnails, rows.Err()
}

// thumbnailURL is ProductFile#thumbnail_url. A video's comes from the variant URL Rails
// caches; on a miss it is the variant's own, or the upload's where thumbnail_variant is nil
// and its rescue answers. A variant still to be made is Rails', which resizes it in-request.
func (c ContentConfig) thumbnailURL(l *loader, d *displayFile, t *thumbnail) (any, error) {
	if t == nil || !d.streamable() && !d.renderableImage() {
		return nil, nil
	}
	if !t.blobID.Valid {
		// thumbnail.url raises, in the rescue too.
		return nil, ErrUnported
	}
	original := c.PublicStorage + t.key.String
	if d.renderableImage() {
		return c.CDNMap.URLFor(original), nil
	}
	if c.Cache == nil {
		return nil, ErrUnported
	}
	cached, found, err := c.Cache.Read(l.ctx, "attachment_product_file_thumbnail_"+strconv.FormatInt(t.attachmentID, 10)+"_variant_url")
	if err != nil {
		return nil, ErrUnported
	}
	if found {
		url, ok := cached.(string)
		if !ok {
			return nil, ErrUnported
		}
		return c.CDNMap.URLFor(url), nil
	}
	contentType := t.contentType.String
	if !strings.HasPrefix(contentType, "image") || !supportedThumbnailType.MatchString(contentType) || !storage.Variable(contentType) {
		// thumbnail_variant is nil, or variant raises; either way the rescue answers.
		return c.CDNMap.URLFor(original), nil
	}
	var variantKey sql.NullString
	err = l.conn.QueryRowContext(l.ctx, "SELECT variant_blobs.key FROM active_storage_variant_records"+
		" LEFT JOIN active_storage_attachments variant_images ON variant_images.record_type = 'ActiveStorage::VariantRecord'"+
		" AND variant_images.record_id = active_storage_variant_records.id AND variant_images.name = 'image'"+
		" LEFT JOIN active_storage_blobs variant_blobs ON variant_blobs.id = variant_images.blob_id"+
		" WHERE active_storage_variant_records.blob_id = ? AND active_storage_variant_records.variation_digest = ? LIMIT 1",
		t.blobID.Int64, storage.VariantDigest(t.filename.String, contentType, 1280, 720)).Scan(&variantKey)
	switch {
	case err == sql.ErrNoRows:
		return nil, ErrUnported
	case err != nil:
		return nil, err
	case !variantKey.Valid:
		// The record's image isn't attached, so its url raises into the rescue.
		return c.CDNMap.URLFor(original), nil
	}
	return c.CDNMap.URLFor(c.PublicStorage + variantKey.String), nil
}
