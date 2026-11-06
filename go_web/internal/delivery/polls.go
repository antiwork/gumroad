package delivery

import (
	"context"
	"database/sql"
	"math"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/obfuscate"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// MediaLocation::Unit.
const (
	unitPageNumber = "page_number"
	unitSeconds    = "seconds"
	unitPercentage = "percentage"
)

const (
	// An EPUB's content_length: its locations are percentages.
	epubContentLength = 100
	// Where a page-number row on an EPUB stops: only the web reader's CFI-aware writes may
	// report the end of the book.
	maxEPUBPagePercentage = 99
)

// AudioDurations is UrlRedirectsController#audio_durations_data, for files from AliveProductFiles.
func AudioDurations(files []ProductFile, ids *obfuscate.IDs) *rails.RHash {
	h := rails.NewRHash()
	for _, f := range files {
		if f.audio {
			h.Str(ids.Encrypt(f.ID), f.contentLength())
		}
	}
	return h
}

// LatestMediaLocations is UrlRedirectsController#latest_media_locations_data. purchaseID is
// @url_redirect.purchase's id, nil when that row is missing; hasInstallment is
// @url_redirect.installment.present?; files come from AliveProductFiles.
func LatestMediaLocations(ctx context.Context, conn *sql.DB, purchaseID *int64, hasInstallment bool, files []ProductFile, ids *obfuscate.IDs) (*rails.RHash, error) {
	h := rails.NewRHash()
	if purchaseID == nil || hasInstallment {
		return h, nil
	}
	locations, err := maxConsumedAtByFile(ctx, conn, *purchaseID)
	if err != nil {
		return nil, err
	}
	for _, f := range files {
		h.Str(ids.Encrypt(f.ID), f.mediaLocationForDownloadPage(locations[f.ID]))
	}
	return h, nil
}

type mediaLocation struct {
	location   int64
	unit       sql.NullString
	consumedAt db.NullTime
}

// maxConsumedAtByFile is MediaLocation.max_consumed_at_by_file(purchase_id:).index_by(&:product_file_id).
// The query has no ORDER BY, and every row tied at a file's latest consumed_at comes back, so
// index_by keeps whichever MySQL returns last; both join orders read a purchase's rows in
// primary-key order, which makes that the highest id.
func maxConsumedAtByFile(ctx context.Context, conn *sql.DB, purchaseID int64) (map[int64]*mediaLocation, error) {
	rows, err := conn.QueryContext(ctx, "SELECT `media_locations`.`product_file_id`, `media_locations`.`location`, `media_locations`.`unit`,"+
		" `media_locations`.`consumed_at` FROM `media_locations` INNER JOIN (SELECT product_file_id, MAX(consumed_at) AS max_consumed_at"+
		" FROM `media_locations` WHERE `media_locations`.`purchase_id` = ? GROUP BY `media_locations`.`product_file_id`) AS max_ml"+
		" ON media_locations.product_file_id = max_ml.product_file_id AND media_locations.consumed_at = max_ml.max_consumed_at"+
		" WHERE `media_locations`.`purchase_id` = ?", purchaseID, purchaseID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	byFile := map[int64]*mediaLocation{}
	for rows.Next() {
		var fileID int64
		m := &mediaLocation{}
		if err := rows.Scan(&fileID, &m.location, &m.unit, &m.consumedAt); err != nil {
			return nil, err
		}
		byFile[fileID] = m
	}
	return byFile, rows.Err()
}

func (f *ProductFile) listenable() bool { return f.Filegroup == "audio" }
func (f *ProductFile) streamable() bool { return f.Filegroup == "video" }
func (f *ProductFile) epub() bool       { return f.Filetype == "epub" }
func (f *ProductFile) readable() bool   { return f.Filetype == "pdf" || f.epub() }

// contentLength is ProductFile#content_length.
func (f *ProductFile) contentLength() any {
	switch {
	case f.listenable() || f.streamable():
		return nullableInt(f.Duration)
	case f.epub():
		return int64(epubContentLength)
	}
	return nullableInt(f.Pagelength)
}

// mediaLocationCompatible is ProductFile#media_location_compatible?.
func (f *ProductFile) mediaLocationCompatible(m *mediaLocation) bool {
	// A NULL unit equals none of the units.
	if m == nil || !m.unit.Valid {
		return false
	}
	switch unit := m.unit.String; {
	case f.listenable() || f.streamable():
		return unit == unitSeconds
	case f.epub():
		return unit == unitPageNumber || unit == unitPercentage
	case f.readable():
		return unit == unitPageNumber
	}
	return false
}

// mediaLocationForDownloadPage is ProductFile#media_location_for_download_page: nil, or the
// location's as_json(include_epub_cfi: false).
func (f *ProductFile) mediaLocationForDownloadPage(m *mediaLocation) any {
	if !f.mediaLocationCompatible(m) {
		return nil
	}
	var timestamp any
	if m.consumedAt.Valid {
		timestamp = m.consumedAt.Time.In(time.UTC)
	}
	json := rails.NewRHash().Sym("location", m.location).Sym("unit", m.unit.String).Sym("timestamp", timestamp)
	if !f.epub() || m.unit.String != unitPageNumber {
		return json
	}
	if f.Pagelength == nil || *f.Pagelength <= 0 {
		return nil
	}
	// (location.fdiv(pagelength) * 100).floor.clamp(0, 99), in the same two roundings.
	ratio := float64(m.location) / float64(*f.Pagelength)
	percent := math.Floor(float64(ratio * 100))
	location := int64(maxEPUBPagePercentage)
	switch {
	case percent < 0:
		location = 0
	case percent < maxEPUBPagePercentage:
		location = int64(percent)
	}
	return json.Sym("location", location).Sym("unit", unitPercentage)
}

func nullableInt(n *int64) any {
	if n == nil {
		return nil
	}
	return *n
}
