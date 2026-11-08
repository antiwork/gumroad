package products

import (
	"context"
	"database/sql"
	"encoding/json"
	"math"
	"math/big"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/antiwork/gumroad/go_web/internal/delivery"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// attributesProps is ProductProps#attributes_props: the custom attributes with a name or
// value, then file_info_for_product_page.
func attributesProps(j jsonData, prod *product, files []productFile) ([]any, error) {
	out := []any{}
	if raw, ok := j.present("custom_attributes"); ok {
		list, isList := raw.([]any)
		if !isList {
			return nil, fallback("custom attributes")
		}
		for _, item := range list {
			attr, isHash := item.(*rails.Hash)
			if !isHash {
				return nil, fallback("custom attributes")
			}
			name, value := attr.Value("name"), attr.Value("value")
			if !jsonScalar(name) || !jsonScalar(value) {
				return nil, fallback("custom attributes")
			}
			if rails.Present(name) || rails.Present(value) {
				out = append(out, rails.NewRHash().Sym("name", name).Sym("value", value))
			}
		}
	}
	info, err := fileInfo(j, prod, files)
	if err != nil {
		return nil, err
	}
	for _, kv := range info {
		out = append(out, rails.NewRHash().Sym("name", kv[0]).Sym("value", kv[1]))
	}
	return out, nil
}

// jsonScalar is a value this port encodes as Rails does: a string, number, bool or null.
func jsonScalar(v any) bool {
	switch v.(type) {
	case nil, string, bool, json.Number:
		return true
	}
	return false
}

// fileInfo is file_info_for_product_page: a lone file's WithFileProperties#file_info, less
// the removed_file_info_attributes.
func fileInfo(j jsonData, prod *product, files []productFile) ([][2]string, error) {
	if len(files) != 1 || prod.is(productIsBundle) {
		return nil, nil
	}
	f := files[0]
	if f.filegroup.String == "image" && prod.requireShipping.Bool {
		return nil, nil
	}
	var removed []string
	if raw, ok := j.present("removed_file_info_attributes"); ok {
		list, isList := raw.([]any)
		if !isList {
			return nil, fallback("removed file info")
		}
		for _, r := range list {
			s, isString := r.(string)
			if !isString {
				return nil, fallback("removed file info")
			}
			removed = append(removed, s)
		}
	}
	var out [][2]string
	add := func(key, value string) {
		if rails.Present(value) && !slices.Contains(removed, key) {
			out = append(out, [2]string{key, value})
		}
	}
	if f.size.Valid {
		size, ok := numberToHumanSize(f.size.Int64)
		if !ok {
			return nil, fallback("file size")
		}
		add("Size", size)
	}
	duration, ok := durationDisplayable(f.duration)
	if !ok {
		return nil, fallback("file duration")
	}
	add("Duration", duration)
	if f.pagelength.Valid {
		unit := "page"
		if f.filetype.String == "epub" {
			unit = "section"
		}
		add("Length", pluralize(f.pagelength.Int64, unit))
	}
	if f.width.Valid && f.height.Valid {
		switch w, h := f.width.Int64, f.height.Int64; {
		case w == 1920 && h == 1080:
			add("Resolution", "1080p")
		case w == 1280 && h == 720:
			add("Resolution", "720p")
		case w == 854 && h == 480:
			add("Resolution", "480p")
		default:
			add("Resolution", strconv.FormatInt(w, 10)+" x "+strconv.FormatInt(h, 10)+" px")
		}
	}
	return out, nil
}

// pluralize is ActionView's pluralize(count, singular) for these regular nouns.
func pluralize(n int64, singular string) string {
	if n == 1 {
		return "1 " + singular
	}
	return strconv.FormatInt(n, 10) + " " + singular + "s"
}

// durationDisplayable is InfosHelper#duration_displayable. ok is false for a negative
// duration, which Rails formats from a local time in year -1.
func durationDisplayable(d sql.NullInt64) (string, bool) {
	t := time.Unix(0, 0).UTC().Add(time.Duration(d.Int64) * time.Second)
	switch {
	case !d.Valid || d.Int64 == 0:
		return "", true
	case d.Int64 < 0:
		return "", false
	case d.Int64 < 60:
		return t.Format("0:05"), true
	case d.Int64 < 600:
		return strings.TrimPrefix(t.Format("04:05"), "0"), true
	}
	return strconv.FormatInt(d.Int64/60, 10) + " minutes", true
}

// storageUnits are the en locale's human.storage_units.units past bytes.
var storageUnits = []string{"KB", "MB", "GB", "TB", "PB", "EB", "ZB"}

// numberToHumanSize is ActionView's number_to_human_size with the en locale: precision 3,
// significant, insignificant zeros stripped, and BigDecimal's half-up rounding of the
// Float's shortest repr. ok is false where Ruby's float logarithms could disagree.
func numberToHumanSize(size int64) (string, bool) {
	if size < 0 || size >= 1<<53 {
		return "", false
	}
	if size < 1024 {
		if size == 1 {
			return "1 Byte", true
		}
		return strconv.FormatInt(size, 10) + " Bytes", true
	}
	number := float64(size)
	exp := int(math.Log(number) / math.Log(1024))
	exact := 0
	for p := int64(1024); p <= size && exact < len(storageUnits); p *= 1024 {
		exact++
	}
	if exp != exact || exp < 1 {
		return "", false
	}
	human := number / math.Pow(1024, float64(exp))
	// BigDecimal(human.to_s), rounded to 3 significant digits.
	d, ok := new(big.Rat).SetString(strconv.FormatFloat(human, 'f', -1, 64))
	if !ok {
		return "", false
	}
	digits := intDigits(d)
	if float := int(math.Floor(math.Log10(human) + 1)); float != digits {
		return "", false
	}
	rounded := roundHalfUp(d, 3-digits)
	rdigits := intDigits(rounded)
	precision := max(3-rdigits, 0)
	s := rounded.FloatString(precision)
	if strings.Contains(s, ".") {
		s = strings.TrimRight(s, "0")
		s = strings.TrimSuffix(s, ".")
	}
	return s + " " + storageUnits[exp-1], true
}

// intDigits is RoundingHelper#digit_count for a value of at least 1.
func intDigits(r *big.Rat) int {
	q := new(big.Int).Quo(r.Num(), r.Denom())
	if q.Sign() == 0 {
		return 1
	}
	return len(q.String())
}

// roundHalfUp is BigDecimal#round(places, :half_up).
func roundHalfUp(r *big.Rat, places int) *big.Rat {
	scale := new(big.Rat).SetInt(new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(abs(places))), nil))
	x := new(big.Rat).Set(r)
	if places >= 0 {
		x.Mul(x, scale)
	} else {
		x.Quo(x, scale)
	}
	half := big.NewRat(1, 2)
	x.Add(x, half)
	q := new(big.Int).Quo(x.Num(), x.Denom())
	out := new(big.Rat).SetInt(q)
	if places >= 0 {
		return out.Quo(out, scale)
	}
	return out.Mul(out, scale)
}

func abs(n int) int {
	if n < 0 {
		return -n
	}
	return n
}

// fileSummaries is Product::FileSummaryService#perform: one summary shared by every option, or
// one per option.
func (h *handler) fileSummaries(ctx context.Context, prod *product, files []productFile, vs *variants) (*rails.RHash, error) {
	if prod.is(productIsPhysical) || prod.is(productIsBundle) {
		return rails.NewRHash().Sym("product", nil).Sym("options", rails.NewRHash()), nil
	}
	productContents, err := h.richContents(ctx, "Link", []int64{prod.id})
	if err != nil {
		return nil, err
	}
	contents := productContents[prod.id]
	shared, variantContents, err := h.productLevelRichContent(ctx, prod, contents, vs)
	if err != nil {
		return nil, err
	}
	options := rails.NewRHash()
	if shared {
		summary, err := h.summarize(contents, files)
		if err != nil {
			return nil, err
		}
		if summary != nil {
			for _, o := range vs.options {
				options.Str(o.externalID, summary)
			}
		}
		return rails.NewRHash().Sym("product", nullableRHash(summary)).Sym("options", options), nil
	}
	ids := variantIDs(vs.options)
	// The Variants' pages recoverable_hidden_variant_rich_content? read aren't SKUs'.
	if variantContents == nil || prod.is(productSkusEnabled) {
		if variantContents, err = h.richContents(ctx, "BaseVariant", ids); err != nil {
			return nil, err
		}
	}
	optionFiles, err := h.variantFiles(ctx, ids)
	if err != nil {
		return nil, err
	}
	for _, o := range vs.options {
		summary, err := h.summarize(variantContents[o.id], optionFiles[o.id])
		if err != nil {
			return nil, err
		}
		if summary != nil {
			options.Str(o.externalID, summary)
		}
	}
	return rails.NewRHash().Sym("product", nil).Sym("options", options), nil
}

// productLevelRichContent is has_product_level_rich_content? for a product that isn't physical,
// with the Variants' pages when recoverable_hidden_variant_rich_content? read them all.
func (h *handler) productLevelRichContent(ctx context.Context, prod *product, contents []*delivery.RichContent,
	vs *variants) (bool, map[int64][]*delivery.RichContent, error) {
	if len(vs.all) == 0 {
		return true, nil, nil
	}
	if !prod.is(productSameRichContentForAllVariants) {
		return false, nil, nil
	}
	if has, err := anyEditorContent(contents); err != nil || has {
		return has, nil, err
	}
	all, err := h.richContents(ctx, "BaseVariant", variantIDs(vs.all))
	if err != nil {
		return false, nil, err
	}
	for _, o := range vs.all {
		if has, err := anyEditorContent(all[o.id]); err != nil || has {
			return false, all, err
		}
	}
	return true, all, nil
}

func nullableRHash(h *rails.RHash) any {
	if h == nil {
		return nil
	}
	return h
}

// summarize is FileSummaryService#summarize: the files the pages embed, else all of them,
// without external links.
func (h *handler) summarize(contents []*delivery.RichContent, files []productFile) (*rails.RHash, error) {
	var embedded []int64
	for _, c := range contents {
		ids, err := delivery.EmbeddedProductFileIDs(c.DescriptionJSON, h.c.IDs)
		if err != nil {
			return nil, fallback("rich content")
		}
		embedded = append(embedded, ids...)
	}
	var delivered []productFile
	for _, f := range files {
		if (len(embedded) == 0 || slices.Contains(embedded, f.id)) && f.filetype.String != "link" {
			delivered = append(delivered, f)
		}
	}
	if len(delivered) == 0 {
		return nil, nil
	}
	formats := []string{}
	total, hasNil := int64(0), false
	for _, f := range delivered {
		up, ok := fileTypeUpcase(f.filetype.String)
		if !ok {
			return nil, fallback("file type")
		}
		if rails.Present(up) && !slices.Contains(formats, up) {
			formats = append(formats, up)
		}
		if !f.size.Valid {
			hasNil = true
		}
		total += f.size.Int64
	}
	slices.Sort(formats)
	var totalSize any = total
	if hasNil {
		totalSize = nil
	}
	return rails.NewRHash().Sym("formats", formats).Sym("total_size", totalSize).Sym("count", int64(len(delivered))), nil
}

// fileTypeUpcase is String#upcase for a file type: ASCII's, with any character that has no case,
// such as the quote a filename can end in, left as is. A letter outside ASCII is Rails'.
func fileTypeUpcase(s string) (string, bool) {
	var b strings.Builder
	b.Grow(len(s))
	for _, r := range s {
		switch {
		case r < utf8.RuneSelf:
			if 'a' <= r && r <= 'z' {
				r -= 'a' - 'A'
			}
		case r == utf8.RuneError || !unicode.In(r, unicode.M, unicode.N, unicode.P, unicode.S, unicode.Zs) ||
			unicode.ToUpper(r) != r || unicode.SimpleFold(r) != r:
			// Letters, and code points Go's tables leave unassigned, which Ruby's may case.
			return "", false
		}
		b.WriteRune(r)
	}
	return b.String(), true
}

// asciiUpcase is String#upcase where it is ASCII's; other text is Rails'.
func asciiUpcase(s string) (string, bool) {
	b := []byte(s)
	for i, c := range b {
		if c >= 0x80 {
			return "", false
		}
		if c >= 'a' && c <= 'z' {
			b[i] = c - 32
		}
	}
	return string(b), true
}
