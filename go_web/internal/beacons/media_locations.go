package beacons

import (
	"database/sql"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/oauth"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

var platforms = map[string]bool{"web": true, "iphone": true, "android": true, "other": true}

const (
	maxEpubCFILength = 1024
	unitSeconds      = "seconds"
	unitPercentage   = "percentage"
	unitPageNumber   = "page_number"
	// media_locations.location is a 4-byte integer.
	minLocation = math.MinInt32
	maxLocation = math.MaxInt32
)

var (
	// MediaLocation::EPUB_CFI_PATTERN. Its possessive quantifier changes nothing here: the
	// alternatives start with different characters, so there is one way to match.
	epubCFIPattern = regexp.MustCompile(`\Aepubcfi\((?:/\d+(?:\[(?:\^.|[^\]\r\n^])*\])?){2,}!(?:/\d+(?:\[(?:\^.|[^\]\r\n^])*\])?)+(?:[^\r\n()]*)\)\z`)

	successTrue      = rails.NewStatic(`{"success":true}`)
	successFalse     = rails.NewStatic(`{"success":false}`)
	invalidMobileReq = rails.NewStatic(rails.EncodeJSON(rails.NewRHash().Sym("success", false).Sym("message", "Invalid request")))

	errLocationRange = errors.New("location is out of range for ActiveModel::Type::Integer with limit 4 bytes")
)

func (h *handlers) mediaLocation(c *actionContext) error {
	return h.renderMediaLocation(c)
}

// mobileMediaLocation is Api::Mobile::BaseController#check_mobile_token, then
// doorkeeper_authorize! :mobile_api, then the shared action.
func (h *handlers) mobileMediaLocation(c *actionContext) error {
	if !rails.SecureCompare(rails.ToS(c.req.Param("mobile_token")), h.deps.MobileToken) {
		rails.RenderStaticJSON(c.w, c.req, http.StatusUnauthorized, invalidMobileReq)
		return nil
	}
	if !oauth.Authorize(c.w, c.req, c.token, "mobile_api") {
		return nil
	}
	return h.renderMediaLocation(c)
}

func (h *handlers) renderMediaLocation(c *actionContext) error {
	success, err := h.recordMediaLocation(c)
	if err != nil {
		return err
	}
	body := successFalse
	if success {
		body = successTrue
	}
	rails.RenderStaticJSON(c.w, c.req, http.StatusOK, body)
	return nil
}

type productFile struct {
	filetype, filegroup string
}

func (f *productFile) epub() bool       { return f.filetype == "epub" }
func (f *productFile) streamable() bool { return f.filegroup == "video" }
func (f *productFile) listenable() bool { return f.filegroup == "audio" }
func (f *productFile) readable() bool   { return f.filetype == "pdf" || f.epub() }
func (f *productFile) consumable() bool { return f.streamable() || f.listenable() || f.readable() }

// mediaLocationRows is everything record_media_location reads, fetched in one statement.
type mediaLocationRows struct {
	redirectFound         bool
	purchaseID, productID sql.NullInt64
	fileID                sql.NullInt64
	file                  productFile
	locationID            sql.NullInt64
	location              sql.NullInt64
	epubCFI, unit         sql.NullString
	consumedAt            *time.Time
}

// recordMediaLocation is RecordMediaLocation#record_media_location, checks in Rails' order.
func (h *handlers) recordMediaLocation(c *actionContext) (bool, error) {
	req := c.req
	location := req.Param("location")
	if rails.Blank(req.Param("url_redirect_id")) || rails.Blank(req.Param("product_file_id")) || rails.Blank(location) {
		return false, nil
	}
	platform, isString := req.Param("platform").(string)
	if !isString || !platforms[platform] {
		return false, nil
	}
	urlRedirectID := h.decrypt(req.Param("url_redirect_id"))
	purchaseParam := rails.Present(req.Param("purchase_id"))
	var purchaseFromParam *int64
	if purchaseParam {
		purchaseFromParam = h.decrypt(req.Param("purchase_id"))
	}
	fileID := h.decrypt(req.Param("product_file_id"))

	rows, err := h.readMediaLocation(c, urlRedirectID, purchaseParam, purchaseFromParam, fileID, platform)
	if err != nil {
		return false, err
	}
	// Without purchase_id, UrlRedirect.find raises RecordNotFound, a 404.
	if !purchaseParam && !rows.redirectFound {
		return false, errNotFound
	}
	// The join only finds a product through a purchase, so this is product_id.blank? ||
	// purchase_id.blank?.
	if !rows.productID.Valid {
		return false, nil
	}

	consumedAt, err := consumedAtParam(c)
	if err != nil {
		if errors.Is(err, rails.ErrUnsupportedTime) {
			c.logger().Warn("Declining a media location with an unparsed consumed_at", "consumed_at", rails.ToS(req.Param("consumed_at")))
			return false, nil
		}
		return false, err
	}

	// ProductFile.find raises RecordNotFound, a 404.
	if !rows.fileID.Valid {
		return false, errNotFound
	}
	if !rows.file.consumable() {
		return false, nil
	}
	var epubCFI *string
	if rows.file.epub() && rails.Present(req.Param("epub_cfi")) {
		cfi, isString := req.Param("epub_cfi").(string)
		if !isString || utf8.RuneCountInString(cfi) > maxEpubCFILength || !epubCFIPattern.MatchString(cfi) || !epubPercentage(location) {
			return false, nil
		}
		epubCFI = &cfi
	}
	return h.saveMediaLocation(c, rows, mediaLocationWrite{
		urlRedirectID: urlRedirectID, purchaseID: rows.purchaseID.Int64, productFileID: rows.fileID.Int64,
		productID: rows.productID.Int64, platform: platform, location: location, epubCFI: epubCFI,
		consumedAt: consumedAt, unit: mediaLocationUnit(&rows.file, epubCFI != nil),
	})
}

// readMediaLocation reads the url redirect's purchase, the purchase's product, the file and
// the find_or_initialize_by match in one statement; recordMediaLocation then checks them in
// Rails' order.
func (h *handlers) readMediaLocation(c *actionContext, urlRedirectID *int64, purchaseParam bool, purchaseFromParam, fileID *int64, platform string) (*mediaLocationRows, error) {
	rows := &mediaLocationRows{}
	err := h.deps.DB.QueryRowContext(c.ctx, `SELECT redirect.id IS NOT NULL, purchase.id, product.id,
		file.id, COALESCE(file.filetype, ''), COALESCE(file.filegroup, ''),
		location.id, location.location, location.epub_cfi, location.unit, location.consumed_at
		FROM (SELECT 1) AS args
		LEFT JOIN url_redirects redirect ON redirect.id = ?
		LEFT JOIN purchases redirect_purchase ON redirect_purchase.id = redirect.purchase_id
		LEFT JOIN purchases purchase ON purchase.id = IF(?, ?, redirect_purchase.id)
		LEFT JOIN links product ON product.id = purchase.link_id
		LEFT JOIN product_files file ON file.id = ?
		LEFT JOIN media_locations location ON location.url_redirect_id = ? AND location.purchase_id = purchase.id
			AND location.product_file_id = file.id AND location.product_id = product.id AND location.platform = ?
		LIMIT 1`,
		nullableInt(urlRedirectID), purchaseParam, nullableInt(purchaseFromParam), nullableInt(fileID), nullableInt(urlRedirectID), platform).
		Scan(&rows.redirectFound, &rows.purchaseID, &rows.productID, &rows.fileID, &rows.file.filetype, &rows.file.filegroup,
			&rows.locationID, &rows.location, &rows.epubCFI, &rows.unit, db.Time(&rows.consumedAt))
	return rows, err
}

// consumedAtParam is params[:consumed_at].present? ? Time.zone.parse(...) : Time.current.
func consumedAtParam(c *actionContext) (*time.Time, error) {
	raw := c.req.Param("consumed_at")
	if !rails.Present(raw) {
		now := c.req.Now.UTC()
		return &now, nil
	}
	s, isString := raw.(string)
	if !isString {
		// Date._parse raises TypeError on anything but a String.
		return nil, errors.New("consumed_at is not a string")
	}
	if t, ok := isoMillis(s); ok {
		return &t, nil
	}
	return rails.ZoneParse(s, c.req.Now)
}

// isoMillis reads Date#toISOString's exact shape, YYYY-MM-DDTHH:MM:SS.sssZ, which every web
// client sends. ok is false for anything else, impossible dates included, which ZoneParse
// then reads as Rails does.
func isoMillis(s string) (time.Time, bool) {
	if len(s) != 24 || s[4] != '-' || s[7] != '-' || s[10] != 'T' || s[13] != ':' || s[16] != ':' || s[19] != '.' || s[23] != 'Z' {
		return time.Time{}, false
	}
	n := func(from, to int) (int, bool) {
		v := 0
		for i := from; i < to; i++ {
			if s[i] < '0' || s[i] > '9' {
				return 0, false
			}
			v = v*10 + int(s[i]-'0')
		}
		return v, true
	}
	parts := [7]int{}
	for i, r := range [7][2]int{{0, 4}, {5, 7}, {8, 10}, {11, 13}, {14, 16}, {17, 19}, {20, 23}} {
		v, ok := n(r[0], r[1])
		if !ok {
			return time.Time{}, false
		}
		parts[i] = v
	}
	year, month, day, hour, minute, second := parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]
	if month < 1 || month > 12 || day < 1 || day > time.Date(year, time.Month(month)+1, 0, 0, 0, 0, 0, time.UTC).Day() ||
		hour > 23 || minute > 59 || second > 59 {
		return time.Time{}, false
	}
	return time.Date(year, time.Month(month), day, hour, minute, second, parts[6]*int(time.Millisecond), time.UTC), true
}

type mediaLocationWrite struct {
	urlRedirectID                        *int64
	purchaseID, productFileID, productID int64
	platform                             string
	location                             any
	epubCFI                              *string
	consumedAt                           *time.Time
	unit                                 string
}

// saveMediaLocation is the consumed_at guard and update!. The UPDATE repeats the guard, so a
// position that arrives after a newer one can't overwrite it.
func (h *handlers) saveMediaLocation(c *actionContext, rows *mediaLocationRows, w mediaLocationWrite) (bool, error) {
	found := rows.locationID.Valid
	if found {
		if w.consumedAt == nil {
			// An unparsed consumed_at is nil, and nil > raises NoMethodError.
			return false, errors.New("undefined method '>' for nil consumed_at")
		}
		// A stored NULL consumed_at reads as older; Rails' comparison would raise on it.
		if rows.consumedAt != nil && !w.consumedAt.After(*rows.consumedAt) {
			return false, nil
		}
	}

	location, present, err := integerCast(w.location)
	// validates_presence_of runs before serialization; RecordInvalid is a 422.
	if w.urlRedirectID == nil || (!present && err == nil) {
		return false, statusError(http.StatusUnprocessableEntity)
	}
	if err != nil {
		return false, err
	}
	// datetime precision nil is DATETIME(0); Rails truncates before MySQL would round.
	var consumed *time.Time
	if w.consumedAt != nil {
		t := w.consumedAt.UTC().Truncate(time.Second)
		consumed = &t
	}
	now := c.req.Now.UTC().Truncate(time.Microsecond)
	ctx, cancel := c.writeContext()
	defer cancel()

	if !found {
		_, err := h.deps.DB.ExecContext(ctx, `INSERT INTO media_locations
			(product_file_id, url_redirect_id, purchase_id, product_id, consumed_at, platform, location, content_length, unit, created_at, updated_at, epub_cfi)
			VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?)`,
			w.productFileID, *w.urlRedirectID, w.purchaseID, w.productID, consumed, w.platform, location, w.unit, now, now, w.epubCFI)
		return err == nil, err
	}

	var sets []string
	var args []any
	if rows.location.Int64 != location {
		sets, args = append(sets, "location = ?"), append(args, location)
	}
	if (w.epubCFI == nil) != !rows.epubCFI.Valid || (w.epubCFI != nil && *w.epubCFI != rows.epubCFI.String) {
		sets, args = append(sets, "epub_cfi = ?"), append(args, w.epubCFI)
	}
	if consumed != nil && (rows.consumedAt == nil || !consumed.Equal(*rows.consumedAt)) {
		sets, args = append(sets, "consumed_at = ?"), append(args, *consumed)
	}
	if !rows.unit.Valid || rows.unit.String != w.unit {
		sets, args = append(sets, "unit = ?"), append(args, w.unit)
	}
	if len(sets) == 0 {
		return true, nil
	}
	// The new time can sit in the stored second and still be later, as Ruby compares them.
	fraction := w.consumedAt.Sub(*consumed) > 0
	sets = append(sets, "updated_at = ?")
	args = append(args, now, rows.locationID.Int64, *consumed, fraction, *consumed)
	result, err := h.deps.DB.ExecContext(ctx, `UPDATE media_locations SET `+strings.Join(sets, ", ")+
		` WHERE id = ? AND (consumed_at IS NULL OR consumed_at < ? OR (? AND consumed_at = ?))`, args...)
	if err != nil {
		return false, err
	}
	affected, err := result.RowsAffected()
	return err == nil && affected > 0, err
}

// mediaLocationUnit is MediaLocation#add_unit.
func mediaLocationUnit(f *productFile, hasCFI bool) string {
	switch {
	case f.streamable() || f.listenable():
		return unitSeconds
	case f.epub() && hasCFI:
		return unitPercentage
	case f.readable():
		return unitPageNumber
	}
	return unitPercentage
}

// epubPercentage is MediaLocation.valid_epub_percentage?: Float(value, exception: false)
// between 0 and 100.
func epubPercentage(v any) bool {
	var f float64
	switch v := v.(type) {
	case json.Number:
		parsed, err := strconv.ParseFloat(string(v), 64)
		if err != nil {
			return false
		}
		f = parsed
	case string:
		parsed, ok := rubyFloat(v)
		if !ok {
			return false
		}
		f = parsed
	default:
		return false
	}
	return f >= 0 && f <= 100
}

var rubyFloatPattern = regexp.MustCompile(`\A[ \t\n\v\f\r]*[-+]?(?:\d+(?:_\d+)*(?:\.\d+(?:_\d+)*)?(?:[eE][-+]?\d+(?:_\d+)*)?|0[xX][0-9a-fA-F]+(?:_[0-9a-fA-F]+)*)[ \t\n\v\f\r]*\z`)

// rubyFloat is Kernel#Float on a String.
func rubyFloat(s string) (float64, bool) {
	if !rubyFloatPattern.MatchString(s) {
		return 0, false
	}
	s = strings.ReplaceAll(strings.TrimSpace(s), "_", "")
	if strings.Contains(strings.ToLower(s), "0x") {
		n, err := strconv.ParseInt(s, 0, 64)
		return float64(n), err == nil
	}
	f, err := strconv.ParseFloat(s, 64)
	return f, err == nil && !math.IsInf(f, 0)
}

// integerCast is ActiveModel::Type::Integer#cast for the location param: present is false
// where the cast is nil, and err is the ActiveModel::RangeError (a 500) its serialize
// raises past four bytes.
func integerCast(v any) (n int64, present bool, err error) {
	switch v := v.(type) {
	case bool:
		if v {
			return 1, true, nil
		}
		return 0, true, nil
	case string:
		i, ok := rails.StringToI(v)
		if !ok {
			return 0, true, errLocationRange
		}
		n = i
	case json.Number:
		if strings.ContainsAny(string(v), ".eE") {
			f, err := strconv.ParseFloat(string(v), 64)
			if err != nil || math.IsInf(f, 0) {
				// cast_value rescues Infinity.to_i's FloatDomainError to nil.
				return 0, false, nil
			}
			if f = math.Trunc(f); f < minLocation || f > maxLocation {
				return 0, true, errLocationRange
			}
			return int64(f), true, nil
		}
		i, err := strconv.ParseInt(string(v), 10, 64)
		if err != nil {
			return 0, true, errLocationRange
		}
		n = i
	default:
		return 0, false, nil
	}
	if n < minLocation || n > maxLocation {
		return 0, true, errLocationRange
	}
	return n, true, nil
}

// decrypt is ObfuscateIds.decrypt(value.to_s). An array or hash's #to_s never decrypts.
func (h *handlers) decrypt(v any) *int64 {
	s, ok := rails.String(v)
	if !ok {
		return nil
	}
	id, ok := h.deps.IDs.Decrypt(s)
	if !ok {
		return nil
	}
	return &id
}

func nullableInt(v *int64) any {
	if v == nil {
		return nil
	}
	return *v
}
