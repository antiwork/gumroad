package delivery

import (
	"database/sql"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/obfuscate"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

// ProductFile flags (has_flags 1 => :is_transcoded_for_hls ...).
const (
	FileStreamOnly              = 1 << 3
	filePDFStampEnabled         = 1 << 4
	fileHideKindleAndReadButton = 1 << 5
)

const (
	// ProductFile::MAX_EPUB_READER_ARCHIVE_SIZE.
	maxEPUBReaderSize = 32 << 20
	// Link::MAX_ALLOWED_FILE_SIZE_FOR_SEND_TO_KINDLE.
	maxKindleSize = 15_500_000
)

// ProductFile::BROWSER_RENDERABLE_IMAGE_FILETYPES.
var browserRenderableImages = map[string]bool{"png": true, "jpg": true, "jpeg": true, "gif": true, "webp": true}

// ContentConfig is what download_attributes reads from config.
type ContentConfig struct {
	IDs *obfuscate.IDs
	// S3BaseURL is S3_BASE_URL, and AssetHost config.asset_host.
	S3BaseURL, AssetHost string
}

// ContentRedirect is what map_file reads from the url redirect.
type ContentRedirect struct {
	Token  string
	Rental bool
	// ReferencedProductID is referenced_link's id, whose folders hold the files.
	ReferencedProductID *int64
}

// displayFile is a product_files row as map_file reads it.
type displayFile struct {
	ProductFile
	url, displayName, description, isbn sql.NullString
	size, width, height                 sql.NullInt64
	flags                               int64
	folderID, productID                 sql.NullInt64
}

func (f *displayFile) is(flag int64) bool    { return f.flags&flag != 0 }
func (f *displayFile) externalLink() bool    { return f.Filetype == "link" }
func (f *displayFile) pdf() bool             { return f.Filetype == "pdf" }
func (f *displayFile) renderableImage() bool { return browserRenderableImages[f.Filetype] }
func (f *displayFile) browserReadable() bool {
	return f.pdf() || f.epub() && (!f.size.Valid || f.size.Int64 <= maxEPUBReaderSize)
}
func (f *displayFile) streamOnly() bool {
	return StreamOnly(f.Filetype, f.Filegroup, f.size, f.flags)
}

// StreamOnly is ProductFile#stream_only? for a file's columns, NULL strings as "": the flag,
// on a file that can_disable_downloads? (a video, or a PDF or small EPUB the browser reads).
func StreamOnly(filetype, filegroup string, size sql.NullInt64, flags int64) bool {
	f := displayFile{ProductFile: ProductFile{Filetype: filetype, Filegroup: filegroup}, size: size, flags: flags}
	return (f.streamable() || f.browserReadable()) && f.is(FileStreamOnly)
}
func (f *displayFile) canSendToKindle() bool {
	return (f.pdf() || f.epub()) && f.size.Valid && f.size.Int64 < maxKindleSize
}

// displayFiles runs one of aliveProductFiles' queries with download_attributes' select
// list, keeping the rows for ContentItems.
func (l *loader) displayFiles(query string, args ...any) ([]ProductFile, error) {
	rows, err := l.conn.QueryContext(l.ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	columns, err := rows.Columns()
	if err != nil {
		return nil, err
	}
	var files []ProductFile
	for rows.Next() {
		d := &displayFile{}
		var filetype, filegroup sql.NullString
		var pagelength, duration sql.NullInt64
		fields := map[string]any{
			"id": &d.ID, "filetype": &filetype, "filegroup": &filegroup, "pagelength": &pagelength, "duration": &duration,
			"url": &d.url, "display_name": &d.displayName, "description": &d.description, "isbn": &d.isbn, "size": &d.size,
			"width": &d.width, "height": &d.height, "flags": &d.flags, "folder_id": &d.folderID, "link_id": &d.productID,
		}
		dest := make([]any, len(columns))
		for i, c := range columns {
			if dest[i] = fields[c]; dest[i] == nil {
				dest[i] = new(sql.RawBytes)
			}
		}
		if err := rows.Scan(dest...); err != nil {
			return nil, err
		}
		d.Filetype, d.Filegroup = filetype.String, filegroup.String
		if pagelength.Valid {
			d.Pagelength = &pagelength.Int64
		}
		if duration.Valid {
			d.Duration = &duration.Int64
		}
		l.displayed = append(l.displayed, d)
		files = append(files, d.ProductFile)
	}
	return files, rows.Err()
}

// ContentItems is UrlRedirectPresenter#download_attributes[:content_items] for a signed-out
// viewer, without a completed commission's files. ErrUnported covers what only Rails maps:
// thumbnails, subtitles, stamped PDFs, web builds, a post's files and non-ASCII extensions.
func (p *Page) ContentItems(r ContentRedirect, c ContentConfig) ([]any, error) {
	l := p.l
	if _, err := p.Files(); err != nil {
		return nil, err
	}
	files := l.displayed
	if len(files) == 0 {
		return []any{}, nil
	}
	var ids, productIDs []any
	seen, seenProduct := map[int64]bool{}, map[int64]bool{}
	for _, d := range files {
		switch {
		case !d.productID.Valid:
			// with_product_files_owner is a post's.
			return nil, ErrUnported
		case d.is(filePDFStampEnabled):
			return nil, ErrUnported
		}
		if !seen[d.ID] {
			seen[d.ID] = true
			ids = append(ids, d.ID)
		}
		if !seenProduct[d.productID.Int64] {
			seenProduct[d.productID.Int64] = true
			productIDs = append(productIDs, d.productID.Int64)
		}
	}
	in := "(" + placeholders(len(ids)) + ")"
	var subtitles, builds, thumbnails bool
	if err := l.conn.QueryRowContext(l.ctx, "SELECT EXISTS(SELECT 1 FROM subtitle_files WHERE product_file_id IN "+in+" AND deleted_at IS NULL),"+
		" EXISTS(SELECT 1 FROM product_builds WHERE product_file_id IN "+in+"),"+
		" EXISTS(SELECT 1 FROM active_storage_attachments WHERE record_type = 'ProductFile' AND name = 'thumbnail' AND record_id IN "+in+")",
		append(append(append([]any(nil), ids...), ids...), ids...)...).Scan(&subtitles, &builds, &thumbnails); err != nil {
		return nil, err
	}
	if subtitles || builds || thumbnails {
		return nil, ErrUnported
	}

	owners, err := productOwnerExternalIDs(l, productIDs)
	if err != nil {
		return nil, err
	}
	var granted map[int64]bool
	var locations map[int64]*mediaLocation
	if l.r.PurchaseID != nil {
		if locations, err = maxConsumedAtByFile(l.ctx, l.conn, *l.r.PurchaseID); err != nil {
			return nil, err
		}
	}
	var folderIDs []any
	for _, d := range files {
		if d.streamOnly() && granted == nil {
			if granted, err = downloadGrants(l, l.r.ID); err != nil {
				return nil, err
			}
		}
		if d.folderID.Valid {
			folderIDs = append(folderIDs, d.folderID.Int64)
		}
	}
	aliveFolders, folders, err := loadFolders(l, r.ReferencedProductID, folderIDs)
	if err != nil {
		return nil, err
	}
	mapFile := func(d *displayFile) (*rails.RHash, error) {
		return c.mapFile(r, d, owners[d.productID.Int64], locations[d.ID], granted)
	}
	items := []any{}
	for _, folder := range folders {
		children := []any{}
		for _, d := range files {
			if d.folderID.Valid && d.folderID.Int64 == folder.id {
				m, err := mapFile(d)
				if err != nil {
					return nil, err
				}
				children = append(children, m)
			}
		}
		items = append(items, rails.NewRHash().Sym("type", "folder").Sym("id", c.IDs.Encrypt(folder.id)).
			Sym("name", nullString(folder.name)).Sym("children", children))
	}
	for _, d := range files {
		// !file.external_folder_id: no folder, or one that isn't alive.
		if d.folderID.Valid && aliveFolders[d.folderID.Int64] {
			continue
		}
		m, err := mapFile(d)
		if err != nil {
			return nil, err
		}
		items = append(items, m)
	}
	return items, nil
}

// productOwnerExternalIDs is each product's user.external_id, the users column.
func productOwnerExternalIDs(l *loader, productIDs []any) (map[int64]string, error) {
	rows, err := l.conn.QueryContext(l.ctx, "SELECT links.id, users.external_id FROM links JOIN users ON users.id = links.user_id"+
		" WHERE links.id IN ("+placeholders(len(productIDs))+")", productIDs...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	owners := map[int64]string{}
	for rows.Next() {
		var id int64
		var external sql.NullString
		if err := rows.Scan(&id, &external); err != nil {
			return nil, err
		}
		owners[id] = external.String
	}
	return owners, rows.Err()
}

func downloadGrants(l *loader, redirectID int64) (map[int64]bool, error) {
	rows, err := l.conn.QueryContext(l.ctx, "SELECT product_file_id FROM product_file_download_grants WHERE url_redirect_id = ?", redirectID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	granted := map[int64]bool{}
	for rows.Next() {
		var id sql.NullInt64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		if id.Valid {
			granted[id.Int64] = true
		}
	}
	return granted, rows.Err()
}

type folder struct {
	id   int64
	name sql.NullString
}

// loadFolders reads which of the files' folders are alive, for external_folder_id, and the
// referenced product's alive ones among them in position order, for the folder items.
func loadFolders(l *loader, productID *int64, folderIDs []any) (map[int64]bool, []folder, error) {
	alive := map[int64]bool{}
	if len(folderIDs) == 0 {
		return alive, nil, nil
	}
	in := "(" + placeholders(len(folderIDs)) + ")"
	rows, err := l.conn.QueryContext(l.ctx, "SELECT id FROM product_folders WHERE deleted_at IS NULL AND id IN "+in, folderIDs...)
	if err != nil {
		return nil, nil, err
	}
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return nil, nil, err
		}
		alive[id] = true
	}
	rows.Close()
	if err := rows.Err(); err != nil || productID == nil {
		return alive, nil, err
	}
	rows, err = l.conn.QueryContext(l.ctx, "SELECT id, name FROM product_folders WHERE product_id = ? AND deleted_at IS NULL AND id IN "+in+
		" ORDER BY position ASC", append([]any{*productID}, folderIDs...)...)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	var folders []folder
	for rows.Next() {
		var f folder
		if err := rows.Scan(&f.id, &f.name); err != nil {
			return nil, nil, err
		}
		folders = append(folders, f)
	}
	return alive, folders, rows.Err()
}

// mapFile is UrlRedirectPresenter#map_file for a signed-out viewer, for a file without a
// thumbnail, subtitles, a web build or PDF stamping. owner is the product's user's
// external_id column.
func (c ContentConfig) mapFile(r ContentRedirect, d *displayFile, owner string, location *mediaLocation, granted map[int64]bool) (*rails.RHash, error) {
	names := s3Names{url: d.url.String, baseURL: c.S3BaseURL, ownerExternalID: owner}
	external := c.IDs.Encrypt(d.ID)
	token := web.EscapeSegment(r.Token)

	// is_file_downloadable?
	downloadable := !d.externalLink() && !(d.streamable() && r.Rental) && (!d.streamOnly() || granted[d.ID])
	var downloadURL any
	if downloadable {
		downloadURL = "/r/" + token + "/product_files?" + rails.CGIEscape("product_file_ids[]") + "=" + rails.CGIEscape(external)
	}

	var name any
	switch {
	case rails.Present(d.displayName.String):
		name = d.displayName.String
	case d.externalLink():
		name = nullString(d.url)
	case names.s3():
		name = names.displayName()
	}

	// display_extension: s3_display_extension.presence || filetype.to_s.upcase.
	var extension any = "URL"
	if !d.externalLink() {
		ext := ""
		if names.s3() {
			var ok bool
			if ext, ok = names.displayExtension(); !ok {
				return nil, ErrUnported
			}
		}
		if !rails.Present(ext) {
			if !ascii(d.Filetype) {
				// String#upcase special-cases letters strings.ToUpper doesn't.
				return nil, ErrUnported
			}
			ext = strings.ToUpper(d.Filetype)
		}
		extension = ext
	}

	var pagelength any
	if !d.epub() {
		pagelength = nullableInt(d.Pagelength)
	}
	var viewURL, streamURL, kindle, readURL, externalURL, width, height any
	if d.renderableImage() {
		viewURL = downloadURL
	}
	if d.streamable() {
		streamURL = "/s/" + token + "/" + web.EscapeSegment(external)
		width, height = nullInt(d.width), nullInt(d.height)
	}
	hideKindleAndRead := d.is(fileHideKindleAndReadButton)
	if d.canSendToKindle() && !hideKindleAndRead {
		kindle = rails.NewRHash().Sym("email", nil).Sym("icon_url", c.AssetHost+"/images/white-15.png")
	}
	if d.browserReadable() && (!hideKindleAndRead || d.streamOnly()) {
		readURL = "/read/" + token + "/" + web.EscapeSegment(external)
	}
	if d.externalLink() {
		externalURL = nullString(d.url)
	}

	return rails.NewRHash().
		Sym("type", "file").
		Sym("file_name", name).
		Sym("description", nullString(d.description)).
		Sym("extension", extension).
		Sym("web_build", nil).
		Sym("file_size", nullInt(d.size)).
		Sym("pagelength", pagelength).
		Sym("duration", nullableInt(d.Duration)).
		Sym("id", external).
		Sym("download_url", downloadURL).
		Sym("archivable", !d.externalLink() && !d.streamOnly()).
		Sym("view_url", viewURL).
		Sym("stream_url", streamURL).
		Sym("kindle_data", kindle).
		Sym("latest_media_location", d.ProductFile.mediaLocationForDownloadPage(location)).
		Sym("content_length", d.ProductFile.contentLength()).
		Sym("isbn", nullString(d.isbn)).
		Sym("read_url", readURL).
		Sym("external_link_url", externalURL).
		Sym("subtitle_files", []any{}).
		Sym("pdf_stamp_enabled", false).
		Sym("processing", false).
		Sym("thumbnail_url", nil).
		Sym("width", width).
		Sym("height", height), nil
}

func nullString(s sql.NullString) any {
	if !s.Valid {
		return nil
	}
	return s.String
}

func nullInt(n sql.NullInt64) any {
	if !n.Valid {
		return nil
	}
	return n.Int64
}

func ascii(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			return false
		}
	}
	return true
}
