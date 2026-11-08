package products

import (
	"context"
	"database/sql"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// publicFilesProps is alive_public_files.attached through PublicFilePresenter#props. The
// eager-loaded query has no ORDER BY; through the resource index its rows come in id order.
func (h *handler) publicFilesProps(ctx context.Context, productID int64) ([]any, error) {
	rows, err := h.c.DB.QueryContext(ctx, `SELECT public_files.id, public_files.public_id, public_files.display_name,
		public_files.file_type, blobs.key, blobs.byte_size
		FROM public_files
		INNER JOIN active_storage_attachments att ON att.record_type = 'PublicFile' AND att.record_id = public_files.id
			AND att.name = 'file'
		LEFT JOIN active_storage_blobs blobs ON blobs.id = att.blob_id
		WHERE public_files.resource_type = 'Link' AND public_files.resource_id = ? AND public_files.deleted_at IS NULL
		ORDER BY public_files.id`, productID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	pc := h.c.Page
	out := []any{}
	var last int64
	for rows.Next() {
		var id int64
		var publicID, name string
		var fileType, key sql.NullString
		var size sql.NullInt64
		if err := rows.Scan(&id, &publicID, &name, &fileType, &key, &size); err != nil {
			return nil, err
		}
		if id == last || !key.Valid {
			// A second attachment (Rails keeps whichever row the join returns first), or a missing
			// blob (file.blob.url raises).
			return nil, fallback("public file attachment")
		}
		last = id
		var extension any
		if fileType.Valid {
			up, ok := fileTypeUpcase(fileType.String)
			if !ok {
				return nil, fallback("public file type")
			}
			extension = up
		}
		out = append(out, rails.NewRHash().
			Sym("id", publicID).
			Sym("name", name).
			Sym("extension", extension).
			Sym("file_size", nullInt(size)).
			Sym("url", pc.cdnURL(pc.PublicStorageURL+key.String)).
			Sym("status", rails.NewRHash().Sym("type", "saved")))
	}
	return out, rows.Err()
}
