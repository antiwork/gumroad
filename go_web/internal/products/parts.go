package products

import (
	"context"
	"database/sql"
	"errors"
	"math"
	"slices"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/storage"
)

// buyPriceCents is Link#price_cents for a buy-only product without recurrence: the last of
// the alive prices in the product's currency that isn't a rental, as preload_product's
// alive_prices loads them.
func (h *handler) buyPriceCents(ctx context.Context, prod *product) (*int64, error) {
	rows, err := h.c.DB.QueryContext(ctx, "SELECT `prices`.`price_cents`, `prices`.`currency`, `prices`.`flags` FROM `prices`"+
		" WHERE `prices`.`deleted_at` IS NULL AND `prices`.`link_id` = ?", prod.id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var last *int64
	for rows.Next() {
		var cents int64
		var cur sql.NullString
		var flags int64
		if err := rows.Scan(&cents, &cur, &flags); err != nil {
			return nil, err
		}
		// prices_for_currency compares with ==, so a NULL currency only matches a NULL one.
		if cur.Valid != prod.priceCurrencyType.Valid || cur.String != prod.priceCurrencyType.String || flags&1 != 0 {
			continue
		}
		c := cents
		last = &c
	}
	return last, rows.Err()
}

// productFile is an alive product_files row, in alive_product_files' order.
type productFile struct {
	id                   int64
	filetype, filegroup  sql.NullString
	size                 sql.NullInt64
	pagelength, duration sql.NullInt64
	width, height        sql.NullInt64
	flags                int64
	isbn                 sql.NullString
}

// ProductFile flag bits.
const fileStreamOnly int64 = 1 << 3

// streamOnly is stream_only? for the files that can be: a video, or anything the browser
// reads. It is conservative, flagging any file with the bit.
func (f productFile) streamOnly() bool { return f.flags&fileStreamOnly != 0 }

func (h *handler) aliveProductFiles(ctx context.Context, productID int64) ([]productFile, error) {
	rows, err := h.c.DB.QueryContext(ctx, "SELECT `product_files`.`id`, `product_files`.`filetype`, `product_files`.`filegroup`,"+
		" `product_files`.`size`, `product_files`.`pagelength`, `product_files`.`duration`, `product_files`.`width`,"+
		" `product_files`.`height`, `product_files`.`flags`, `product_files`.`isbn` FROM `product_files`"+
		" WHERE `product_files`.`link_id` = ? AND `product_files`.`deleted_at` IS NULL ORDER BY `product_files`.`position` ASC", productID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var files []productFile
	for rows.Next() {
		var f productFile
		if err := rows.Scan(&f.id, &f.filetype, &f.filegroup, &f.size, &f.pagelength, &f.duration, &f.width, &f.height, &f.flags, &f.isbn); err != nil {
			return nil, err
		}
		files = append(files, f)
	}
	return files, rows.Err()
}

// reviewStat is the product_review_stats row; nil is ProductReviewStat::TEMPLATE.
type reviewStat struct {
	reviewsCount  int64
	averageRating float64
	// counts are ratings_of_one_count to ratings_of_five_count.
	counts [5]int64
}

func (h *handler) loadReviewStat(ctx context.Context, productID int64) (*reviewStat, error) {
	var s reviewStat
	var average string
	var counts [5]sql.NullInt64
	err := h.c.DB.QueryRowContext(ctx, "SELECT reviews_count, average_rating, ratings_of_one_count, ratings_of_two_count,"+
		" ratings_of_three_count, ratings_of_four_count, ratings_of_five_count FROM product_review_stats WHERE link_id = ? LIMIT 1",
		productID).Scan(&s.reviewsCount, &average, &counts[0], &counts[1], &counts[2], &counts[3], &counts[4])
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	// mysql2 parses the FLOAT column's text, as Float() does.
	f, exact := rails.StringToF(average)
	if !exact {
		return nil, fallback("average rating")
	}
	s.averageRating = f
	for i, c := range counts {
		s.counts[i] = c.Int64
	}
	return &s, nil
}

// ratingStats is Product::ReviewStat#rating_stats.
func (s *reviewStat) ratingStats() *rails.RHash {
	var stat reviewStat
	if s != nil {
		stat = *s
	}
	return rails.NewRHash().
		Sym("count", stat.reviewsCount).
		Sym("average", stat.averageRating).
		Sym("percentages", stat.ratingPercentages())
}

// ratingPercentages is ProductReviewStat#rating_percentages' values: the largest-remainder
// rounding of each count's share.
func (s reviewStat) ratingPercentages() []any {
	out := make([]any, 5)
	if s.reviewsCount == 0 {
		for i := range out {
			out[i] = s.counts[i]
		}
		return out
	}
	percentages := make([]float64, 5)
	type rem struct {
		frac   float64
		rating int
	}
	rems := make([]rem, 5)
	fracs := make([]float64, 5)
	for i, c := range s.counts {
		percentages[i] = float64(c) / float64(s.reviewsCount) * 100
		rems[i] = rem{rubyMod1(percentages[i]), i + 1}
	}
	// sort.reverse of [remainder, rating] pairs: the largest remainder first, the higher
	// rating first among equal remainders.
	for i := 1; i < len(rems); i++ {
		for j := i; j > 0 && (rems[j].frac > rems[j-1].frac || rems[j].frac == rems[j-1].frac && rems[j].rating > rems[j-1].rating); j-- {
			rems[j], rems[j-1] = rems[j-1], rems[j]
		}
	}
	for i, r := range rems {
		fracs[i] = r.frac
	}
	threshold := int(math.Round(kahanSum(fracs)))
	for _, r := range rems[:min(threshold, len(rems))] {
		percentages[r.rating-1]++
	}
	for i, p := range percentages {
		out[i] = int64(math.Floor(p))
	}
	return out
}

// thumbnailURL is product.thumbnail&.alive&.url.
func (h *handler) thumbnailURL(ctx context.Context, productID int64) (any, error) {
	var id int64
	var deleted bool
	var unsplash sql.NullString
	err := h.c.DB.QueryRowContext(ctx, "SELECT `thumbnails`.`id`, `thumbnails`.`deleted_at` IS NOT NULL, `thumbnails`.`unsplash_url`"+
		" FROM `thumbnails` WHERE `thumbnails`.`product_id` = ? LIMIT 1", productID).Scan(&id, &deleted, &unsplash)
	if errors.Is(err, sql.ErrNoRows) || deleted {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if rails.Present(unsplash.String) {
		return unsplash.String, nil
	}
	var blobID sql.NullInt64
	var key, filename, contentType sql.NullString
	err = h.c.DB.QueryRowContext(ctx, `SELECT blobs.id, blobs.key, blobs.filename, blobs.content_type FROM active_storage_attachments att
		LEFT JOIN active_storage_blobs blobs ON blobs.id = att.blob_id
		WHERE att.record_type = 'Thumbnail' AND att.record_id = ? AND att.name = 'file' LIMIT 1`, id).Scan(&blobID, &key, &filename, &contentType)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if !blobID.Valid {
		return nil, fallback("thumbnail blob")
	}
	pc := h.c.Page
	if strings.Contains(contentType.String, "gif") {
		return pc.cdnURL(pc.PublicStorageURL + key.String), nil
	}
	// thumbnail_variant.processed would resize an unprocessed one.
	digest := storage.VariantDigest(filename.String, contentType.String, 600, 600)
	var variantKey sql.NullString
	err = h.c.DB.QueryRowContext(ctx, `SELECT variant_blobs.key FROM active_storage_variant_records
		LEFT JOIN active_storage_attachments variant_images ON variant_images.record_type = 'ActiveStorage::VariantRecord'
			AND variant_images.record_id = active_storage_variant_records.id AND variant_images.name = 'image'
		LEFT JOIN active_storage_blobs variant_blobs ON variant_blobs.id = variant_images.blob_id
		WHERE active_storage_variant_records.blob_id = ? AND active_storage_variant_records.variation_digest = ? LIMIT 1`,
		blobID.Int64, digest).Scan(&variantKey)
	if errors.Is(err, sql.ErrNoRows) || err == nil && !variantKey.Valid {
		return nil, fallback("thumbnail variant")
	}
	if err != nil {
		return nil, err
	}
	if !slices.Contains(variableTypes, contentType.String) {
		return nil, fallback("invariable thumbnail")
	}
	return pc.cdnURL(pc.PublicStorageURL + variantKey.String), nil
}
