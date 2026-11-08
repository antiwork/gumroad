package products

import (
	"context"
	"database/sql"
	"errors"
	"math"
	"slices"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/delivery"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/storage"
)

// priceRow is an alive prices row.
type priceRow struct {
	id         int64
	cents      int64
	currency   sql.NullString
	flags      int64
	recurrence sql.NullString
	// sqlMatch is whether its currency matches the product's in SQL, under the column's collation.
	sqlMatch bool
}

func (r priceRow) isRental() bool { return r.flags&priceIsRental != 0 }

// atDuration is whether default_price keeps the row: a recurring product's buy prices only at
// its subscription duration, without one every price.
func (r priceRow) atDuration(prod *product, duration string) bool {
	return r.isRental() || !prod.is(productIsRecurringBilling) || duration == "" || r.recurrence.Valid && r.recurrence.String == duration
}

// alivePrices is each product's alive_prices, as preload_product and the catalog's includes
// load them.
func (h *handler) alivePrices(ctx context.Context, ids []int64) (map[int64][]priceRow, error) {
	rows, err := h.c.DB.QueryContext(ctx, "SELECT `prices`.`link_id`, `prices`.`id`, `prices`.`price_cents`, `prices`.`currency`,"+
		" `prices`.`flags`, `prices`.`recurrence`, `prices`.`currency` = `links`.`price_currency_type` FROM `prices`"+
		" INNER JOIN `links` ON `links`.`id` = `prices`.`link_id`"+
		" WHERE `prices`.`deleted_at` IS NULL AND `prices`.`link_id` IN ("+placeholders(len(ids))+") ORDER BY `prices`.`id`",
		int64Args(ids)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int64][]priceRow{}
	for rows.Next() {
		var id int64
		var r priceRow
		var sqlMatch sql.NullBool
		if err := rows.Scan(&id, &r.id, &r.cents, &r.currency, &r.flags, &r.recurrence, &sqlMatch); err != nil {
			return nil, err
		}
		r.sqlMatch = sqlMatch.Bool
		out[id] = append(out[id], r)
	}
	return out, rows.Err()
}

// pricesForCurrency is prices_for_currency's rentals or buy prices, from a preload.
func pricesForCurrency(prod *product, prices []priceRow, rental bool) []int64 {
	var out []int64
	for _, r := range prices {
		// prices_for_currency compares with ==, so a NULL currency only matches a NULL one.
		if r.currency.Valid == prod.priceCurrencyType.Valid && r.currency.String == prod.priceCurrencyType.String && r.isRental() == rental {
			out = append(out, r.cents)
		}
	}
	return out
}

// lastPrice is the last of a preload's prices, nil for none; agreed is false when they
// differ, since which one is last is the preload's row order.
func lastPrice(cents []int64) (last *int64, agreed bool) {
	switch {
	case len(cents) == 0:
		return nil, true
	case slices.Min(cents) != slices.Max(cents):
		return nil, false
	}
	return &cents[len(cents)-1], true
}

// lowerOf is the lower of two values, either of which may be missing.
func lowerOf(a, b *int64) *int64 {
	if a == nil || b != nil && *b < *a {
		return b
	}
	return a
}

// prices are the product's alive prices and Link#buy_price_cents and #rental_price_cents: the
// last of each kind in the product's currency, a recurring product's buy price at its
// subscription duration, and nil for a kind the purchase type doesn't offer.
type prices struct {
	buy, rental *int64
	rows        []priceRow
}

func (h *handler) loadPrices(ctx context.Context, prod *product) (prices, error) {
	byProduct, err := h.alivePrices(ctx, []int64{prod.id})
	if err != nil {
		return prices{}, err
	}
	pc := prod.priceCurrencyType
	duration, _ := prod.subscriptionDurationName()
	ps := prices{rows: byProduct[prod.id]}
	for _, r := range ps.rows {
		rental := r.isRental()
		if rental && prod.purchaseType.Int64 == purchaseTypeBuyOnly || !rental && prod.rentOnly() {
			continue
		}
		// prices_for_currency compares with ==, so a NULL currency only matches a NULL one.
		if r.currency.Valid != pc.Valid || r.currency.String != pc.String {
			// The meta tags read prices before the preload, in SQL.
			if r.sqlMatch {
				return prices{}, fallback("price currency collation")
			}
			continue
		}
		if !r.atDuration(prod, duration) {
			continue
		}
		c := r.cents
		if rental {
			ps.rental = &c
		} else {
			ps.buy = &c
		}
	}
	return ps, nil
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

// streamOnly is stream_only?.
func (f productFile) streamOnly() bool {
	return delivery.StreamOnly(f.filetype.String, f.filegroup.String, f.size, f.flags)
}

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
	stats, err := h.reviewStats(ctx, []int64{productID})
	return stats[productID], err
}

// reviewStats is each product's product_review_stat; link_id is unique.
func (h *handler) reviewStats(ctx context.Context, ids []int64) (map[int64]*reviewStat, error) {
	rows, err := h.c.DB.QueryContext(ctx, "SELECT link_id, reviews_count, average_rating, ratings_of_one_count, ratings_of_two_count,"+
		" ratings_of_three_count, ratings_of_four_count, ratings_of_five_count FROM product_review_stats WHERE link_id IN ("+
		placeholders(len(ids))+")", int64Args(ids)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int64]*reviewStat{}
	for rows.Next() {
		var id int64
		var s reviewStat
		var average string
		var counts [5]sql.NullInt64
		if err := rows.Scan(&id, &s.reviewsCount, &average, &counts[0], &counts[1], &counts[2], &counts[3], &counts[4]); err != nil {
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
		out[id] = &s
	}
	return out, rows.Err()
}

// orTemplate is review_stat_proxy: the row, or ProductReviewStat::TEMPLATE's zeros.
func (s *reviewStat) orTemplate() reviewStat {
	if s == nil {
		return reviewStat{}
	}
	return *s
}

// ratingStats is Product::ReviewStat#rating_stats.
// cardRatings is a card's ratings: the count and average when the product displays reviews.
func cardRatings(prod *product, s *reviewStat) any {
	if !prod.is(productDisplayReviews) {
		return nil
	}
	stat := s.orTemplate()
	return rails.NewRHash().Sym("count", stat.reviewsCount).Sym("average", stat.averageRating)
}

func (s *reviewStat) ratingStats() *rails.RHash {
	stat := s.orTemplate()
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
	return h.thumbnailRowURL(ctx, thumbnailRow{id, unsplash})
}

// thumbnailRow is a thumbnails row as Thumbnail#url reads it.
type thumbnailRow struct {
	id       int64
	unsplash sql.NullString
}

// thumbnailRowURL is Thumbnail#url.
func (h *handler) thumbnailRowURL(ctx context.Context, t thumbnailRow) (any, error) {
	urls, err := h.thumbnailURLs(ctx, []thumbnailRow{t})
	return urls[t.id], err
}

// thumbnailURLs is Thumbnail#url for each row, by thumbnail id, in two queries for all of them.
func (h *handler) thumbnailURLs(ctx context.Context, thumbnails []thumbnailRow) (map[int64]any, error) {
	urls := map[int64]any{}
	var ids []int64
	for _, t := range thumbnails {
		if rails.Present(t.unsplash.String) {
			urls[t.id] = t.unsplash.String
		} else {
			ids = append(ids, t.id)
		}
	}
	if len(ids) == 0 {
		return urls, nil
	}
	type file struct {
		blobID                     sql.NullInt64
		key, filename, contentType sql.NullString
	}
	files := map[int64]file{}
	// has_one's query reads the attachments' unique index, so the lowest blob_id wins.
	rows, err := h.c.DB.QueryContext(ctx, `SELECT att.record_id, blobs.id, blobs.key, blobs.filename, blobs.content_type
		FROM active_storage_attachments att LEFT JOIN active_storage_blobs blobs ON blobs.id = att.blob_id
		WHERE att.record_type = 'Thumbnail' AND att.record_id IN (`+placeholders(len(ids))+`) AND att.name = 'file'
		ORDER BY att.record_id, att.blob_id`, int64Args(ids)...)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var id int64
		var f file
		if err := rows.Scan(&id, &f.blobID, &f.key, &f.filename, &f.contentType); err != nil {
			rows.Close()
			return nil, err
		}
		if _, dup := files[id]; !dup {
			files[id] = f
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	pc := h.c.Page
	type variant struct {
		blobID int64
		digest string
	}
	wanted := map[int64]variant{}
	var args []any
	for _, id := range ids {
		f, ok := files[id]
		switch {
		case !ok:
			urls[id] = nil
		case !f.blobID.Valid:
			return nil, fallback("thumbnail blob")
		case strings.Contains(f.contentType.String, "gif") || !storage.Variable(f.contentType.String):
			// Thumbnail#url skips a GIF's variant, and rescues the one file.variant can't make.
			urls[id] = pc.cdnURL(pc.PublicStorageURL + f.key.String)
		default:
			// thumbnail_variant.processed would resize an unprocessed one.
			v := variant{f.blobID.Int64, storage.VariantDigest(f.filename.String, f.contentType.String, 600, 600)}
			wanted[id] = v
			args = append(args, v.blobID, v.digest)
		}
	}
	if len(wanted) == 0 {
		return urls, nil
	}
	rows, err = h.c.DB.QueryContext(ctx, `SELECT active_storage_variant_records.blob_id, active_storage_variant_records.variation_digest,
		variant_blobs.key FROM active_storage_variant_records
		LEFT JOIN active_storage_attachments variant_images ON variant_images.record_type = 'ActiveStorage::VariantRecord'
			AND variant_images.record_id = active_storage_variant_records.id AND variant_images.name = 'image'
		LEFT JOIN active_storage_blobs variant_blobs ON variant_blobs.id = variant_images.blob_id
		WHERE (active_storage_variant_records.blob_id, active_storage_variant_records.variation_digest) IN (`+
		strings.TrimSuffix(strings.Repeat("(?, ?), ", len(wanted)), ", ")+`)`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	keys := map[variant]sql.NullString{}
	for rows.Next() {
		var v variant
		var key sql.NullString
		if err := rows.Scan(&v.blobID, &v.digest, &key); err != nil {
			return nil, err
		}
		keys[v] = key
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for id, v := range wanted {
		key := keys[v]
		if !key.Valid {
			return nil, fallback("thumbnail variant")
		}
		urls[id] = pc.cdnURL(pc.PublicStorageURL + key.String)
	}
	return urls, nil
}
