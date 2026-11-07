package products

import (
	"cmp"
	"context"
	"database/sql"
	"math"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// offerCode is an offer_codes row, with what its scope reads for one product.
type offerCode struct {
	id                                   int64
	code, currencyType, saleLabel        sql.NullString
	amountCents, amountPercentage        sql.NullInt64
	maxPurchaseCount, minimumQuantity    sql.NullInt64
	durationInMonths, minimumAmountCents sql.NullInt64
	universal, existingOnly, newOnly     bool
	validAt, expiresAt, deletedAt        db.NullTime
	flags, tiers                         int64
	// sqlCurrency is whether currency_type matches the product's under the column's collation.
	sqlCurrency                              bool
	hasVariants, excludesProduct, forProduct bool
	// hasOwnershipVariants is ownership_variants.present?, which this port leaves to Rails.
	hasOwnershipVariants bool
	// anyExcluded is excluded_products.present?.
	anyExcluded bool
	// optionIDs is option_ids_by_product and scope the code's options on the product, both read
	// for a code with variants; an empty scope leaves every option in. ownerless is an option
	// without an owning product, which optionIDs leaves out.
	optionIDs *rails.RHash
	scope     map[int64]bool
	ownerless bool
}

// excludes is !applicable_to_variant?. A page without options has none to leave out.
func (c *offerCode) excludes(o *variantOption) bool {
	return o != nil && len(c.scope) > 0 && !c.scope[o.id]
}

// OfferCode's once_per_cart flag bit.
const offerCodeOncePerCart int64 = 1 << 2

// defaultSaleLabel is OfferCode::DEFAULT_SALE_LABEL.
const defaultSaleLabel = "Sale"

// autoApplyCodes is User#auto_apply_offer_code's scope, for user_id = ?.
const autoApplyCodes = "offer_codes.user_id = ? AND offer_codes.deleted_at IS NULL AND offer_codes.universal = 1" +
	" AND offer_codes.auto_apply = 1 AND offer_codes.new_customers_only = 0"

// offerCodeColumns are a code's own columns, which ownDest scans.
const offerCodeColumns = "offer_codes.id, offer_codes.code, offer_codes.currency_type, offer_codes.sale_label," +
	" offer_codes.amount_cents, offer_codes.amount_percentage, offer_codes.max_purchase_count, offer_codes.minimum_quantity," +
	" offer_codes.duration_in_months, offer_codes.minimum_amount_cents, offer_codes.universal, offer_codes.existing_customers_only," +
	" offer_codes.new_customers_only, offer_codes.valid_at, offer_codes.expires_at, offer_codes.deleted_at, offer_codes.flags," +
	" COALESCE(JSON_LENGTH(offer_codes.ownership_duration_tiers), 0)," +
	" EXISTS(SELECT 1 FROM offer_codes_variants v WHERE v.offer_code_id = offer_codes.id)," +
	" EXISTS(SELECT 1 FROM offer_codes_ownership_variants v WHERE v.offer_code_id = offer_codes.id)"

func (c *offerCode) ownDest() []any {
	return []any{&c.id, &c.code, &c.currencyType, &c.saleLabel, &c.amountCents, &c.amountPercentage, &c.maxPurchaseCount,
		&c.minimumQuantity, &c.durationInMonths, &c.minimumAmountCents, &c.universal, &c.existingOnly, &c.newOnly, &c.validAt,
		&c.expiresAt, &c.deletedAt, &c.flags, &c.tiers, &c.hasVariants, &c.hasOwnershipVariants}
}

// loadOfferCode reads the row a condition finds first, nil for none.
func (h *handler) loadOfferCode(ctx context.Context, prod *product, condition string, args ...any) (*offerCode, error) {
	codes, err := h.loadOfferCodes(ctx, prod, condition, args...)
	if err != nil || len(codes) == 0 {
		return nil, err
	}
	return codes[0], nil
}

// loadOfferCodes is loadOfferCode for every row condition finds.
func (h *handler) loadOfferCodes(ctx context.Context, prod *product, condition string, args ...any) ([]*offerCode, error) {
	// excluded_products skips a join row whose product is gone.
	rows, err := h.c.DB.QueryContext(ctx, "SELECT "+offerCodeColumns+", offer_codes.currency_type = ?,"+
		" EXISTS(SELECT 1 FROM offer_codes_excluded_products x INNER JOIN links ON links.id = x.product_id WHERE x.offer_code_id = offer_codes.id),"+
		" EXISTS(SELECT 1 FROM offer_codes_excluded_products x WHERE x.offer_code_id = offer_codes.id AND x.product_id = ?),"+
		" EXISTS(SELECT 1 FROM offer_codes_products j WHERE j.offer_code_id = offer_codes.id AND j.product_id = ?)"+
		" FROM offer_codes WHERE "+condition, append([]any{prod.priceCurrencyType, prod.id, prod.id}, args...)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var codes []*offerCode
	for rows.Next() {
		c := &offerCode{}
		var sqlCurrency sql.NullBool
		if err := rows.Scan(append(c.ownDest(), &sqlCurrency, &c.anyExcluded, &c.excludesProduct, &c.forProduct)...); err != nil {
			return nil, err
		}
		c.sqlCurrency = sqlCurrency.Bool
		codes = append(codes, c)
	}
	return codes, rows.Err()
}

// codeOptionsStatement is OfferCode#variants' statement as Rails writes it, whose row order
// option_ids_by_product keeps.
const codeOptionsStatement = "SELECT `base_variants`.* FROM `base_variants` INNER JOIN `offer_codes_variants`" +
	" ON `base_variants`.`id` = `offer_codes_variants`.`variant_id` WHERE `offer_codes_variants`.`offer_code_id` = ?"

// loadCodeOptions reads a code's option_ids_by_product, grouped by each option's
// owning_product_id, and its scope on prod, restricted_variants_for.
func (h *handler) loadCodeOptions(ctx context.Context, prod *product, c *offerCode) error {
	type option struct {
		id                 int64
		kind               sql.NullString
		categoryID, linkID sql.NullInt64
	}
	var options []*option
	err := scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
		o := &option{}
		cols["id"], cols["type"], cols["variant_category_id"], cols["link_id"] = &o.id, &o.kind, &o.categoryID, &o.linkID
		return func() { options = append(options, o) }
	}, codeOptionsStatement, c.id)
	if err != nil || len(options) == 0 {
		return err
	}
	var categoryIDs []int64
	for _, o := range options {
		if o.kind.String == "Variant" && o.categoryID.Valid {
			categoryIDs = append(categoryIDs, o.categoryID.Int64)
		}
	}
	categoryProducts := map[int64]sql.NullInt64{}
	if len(categoryIDs) > 0 {
		err := scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
			var id int64
			var linkID sql.NullInt64
			cols["id"], cols["link_id"] = &id, &linkID
			return func() { categoryProducts[id] = linkID }
		}, "SELECT id, link_id FROM variant_categories WHERE id IN ("+placeholders(len(categoryIDs))+")", int64Args(categoryIDs)...)
		if err != nil {
			return err
		}
	}
	var order []int64
	byProduct := map[int64][]any{}
	c.scope = map[int64]bool{}
	for _, o := range options {
		owner := o.linkID
		switch o.kind.String {
		case "Variant":
			owner = categoryProducts[o.categoryID.Int64]
		case "Sku":
		default:
			return fallback("offer code option type")
		}
		if !owner.Valid {
			c.ownerless = true
			continue
		}
		if _, ok := byProduct[owner.Int64]; !ok {
			order = append(order, owner.Int64)
		}
		byProduct[owner.Int64] = append(byProduct[owner.Int64], h.c.IDs.Encrypt(o.id))
		if owner.Int64 == prod.id {
			c.scope[o.id] = true
		}
	}
	c.optionIDs = rails.NewRHash()
	for _, id := range order {
		c.optionIDs.Str(h.c.IDs.Encrypt(id), byProduct[id])
	}
	return nil
}

// codeProductIDs is the external ids of a code's products or excluded_products, table being
// their join table, as OfferCodeDiscountComputingService's includes preloads them: in the join
// rows' order, which is whatever MySQL's plan for Rails' own unordered statement gives.
func (h *handler) codeProductIDs(ctx context.Context, table string, codeID int64) ([]any, error) {
	var ids []int64
	err := scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
		var id sql.NullInt64
		cols["product_id"] = &id
		return func() {
			if id.Valid {
				ids = append(ids, id.Int64)
			}
		}
	}, "SELECT `"+table+"`.* FROM `"+table+"` WHERE `"+table+"`.`offer_code_id` = ?", codeID)
	if err != nil || len(ids) == 0 {
		return []any{}, err
	}
	// The preload compacts out a row whose product is gone.
	alive := map[int64]bool{}
	err = scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
		var id int64
		cols["id"] = &id
		return func() { alive[id] = true }
	}, "SELECT links.id FROM links WHERE links.id IN ("+placeholders(len(ids))+")", int64Args(ids)...)
	if err != nil {
		return nil, err
	}
	out := []any{}
	for _, id := range ids {
		if alive[id] {
			out = append(out, h.c.IDs.Encrypt(id))
		}
	}
	return out, nil
}

// unportedLookup is a code whose lookups by string this port can't follow: one whose string
// Unicode normalization or the collation would read differently, or whose currency SQL and
// Ruby compare differently.
func (c *offerCode) unportedLookup(prod *product) string {
	switch {
	case !permalinkParam.MatchString(c.code.String):
		return "offer code characters"
	case c.currencyType.Valid && c.sqlCurrency != c.currencyMatches(prod):
		return "offer code currency"
	}
	return ""
}

// unportedDiscount is a code whose evaluation or discount this port doesn't follow.
func (c *offerCode) unportedDiscount() string {
	switch {
	case c.tiers > 0:
		return "tiered offer code"
	case c.amountCents.Valid == c.amountPercentage.Valid:
		return "offer code amount"
	}
	return ""
}

// currencyMatches is product.price_currency_type == currency_type.
func (c *offerCode) currencyMatches(prod *product) bool {
	return prod.priceCurrencyType.Valid && c.currencyType.Valid && prod.priceCurrencyType.String == c.currencyType.String
}

// currencyValid is OfferCode#is_currency_valid?.
func (c *offerCode) currencyValid(prod *product) bool {
	return c.amountPercentage.Valid || !c.currencyType.Valid || c.currencyMatches(prod)
}

// applicable is OfferCode#applicable?.
func (c *offerCode) applicable(prod *product) bool {
	return c.applicableTo(prod, c.excludesProduct)
}

// applicableTo is applicable? for a product other than the one the code was loaded for, which
// excludes says whether it leaves out.
func (c *offerCode) applicableTo(prod *product, excludes bool) bool {
	if !c.universal {
		return c.forProduct
	}
	return !excludes && (!rails.Present(c.currencyType.String) || c.currencyMatches(prod))
}

// effectiveDefaultCode is effective_default_offer_code, given default_offer_code and
// auto_apply_offer_code_for. capped: the explicit code wins only while it has uses left,
// which counts purchases.
func effectiveDefaultCode(prod *product, explicit, auto *offerCode, now time.Time) (code *offerCode, capped bool) {
	if explicit != nil && explicit.newOnly {
		explicit = nil
	}
	if auto == nil || explicit == nil {
		return cmp.Or(explicit, auto), false
	}
	if explicit.deletedAt.Valid || rails.Blank(explicit.code.String) || explicit.inactive(now) || explicit.existingOnly ||
		!explicit.currencyValid(prod) {
		return auto, false
	}
	return explicit, explicit.maxPurchaseCount.Valid
}

// sellerAutoApply is User#auto_apply_offer_code, read once per page. Its per-product fields
// are for prod, the first product it's read for.
func (h *handler) sellerAutoApply(p *page, prod *product) (*offerCode, error) {
	if p.autoApply == nil && p.hasAutoApplyCode {
		a, err := h.loadOfferCode(p.Ctx, prod, autoApplyCodes+" ORDER BY offer_codes.id ASC LIMIT 1", p.seller.id)
		if err != nil {
			return nil, err
		}
		p.autoApply = a
	}
	return p.autoApply, nil
}

// offerCodesByID is the codes with these ids, by id, with only their own columns.
func (h *handler) offerCodesByID(ctx context.Context, ids []int64) (map[int64]*offerCode, error) {
	out := map[int64]*offerCode{}
	if len(ids) == 0 {
		return out, nil
	}
	rows, err := h.c.DB.QueryContext(ctx, "SELECT "+offerCodeColumns+" FROM offer_codes WHERE offer_codes.id IN ("+placeholders(len(ids))+")",
		int64Args(ids)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		c := &offerCode{}
		if err := rows.Scan(c.ownDest()...); err != nil {
			return nil, err
		}
		out[c.id] = c
	}
	return out, rows.Err()
}

// displayedSaleLabel is sale_label.presence || OfferCode::DEFAULT_SALE_LABEL.
func (c *offerCode) displayedSaleLabel() string {
	if rails.Present(c.saleLabel.String) {
		return c.saleLabel.String
	}
	return defaultSaleLabel
}

// amountOff is OfferCode#amount_off.
func (c *offerCode) amountOff(price int64) int64 {
	switch {
	case c.amountCents.Valid:
		return c.amountCents.Int64
	case !c.amountPercentage.Valid:
		return 0
	}
	return int64(math.Round(float64(price) * (float64(c.amountPercentage.Int64) / 100.0)))
}

// inactive is OfferCode#inactive?.
func (c *offerCode) inactive(now time.Time) bool {
	return c.validAt.Valid && c.validAt.Time.After(now) || c.expiresAt.Valid && c.expiresAt.Time.Before(now)
}

// offerDiscount is what BestOfferCodeService#result gives the visitor, and its sale label.
type offerDiscount struct {
	// listed is whether default_offer_codes is non-empty, which selection_discounts reads.
	listed bool
	// urlCode is the code in the URL, as typed; "" for none.
	urlCode string
	// code is the code that applies, nil for none, and resultCode the string its result
	// echoes: the URL's as typed, else the stored one.
	code       *offerCode
	resultCode string
	// urlError is the URL code's error_code, "" when it applies or there is none. urlRow is that
	// code when it applies, or when an option outside its scope would get option_not_eligible.
	urlError string
	urlRow   *offerCode
	label    any
	// products is the applying code's product_ids, else its excluded_product_ids when universal.
	products []any
	// cents is a fixed code's discount cents, which a once-per-cart code allocates.
	cents         int64
	oncePerCartID string
}

// oncePerCart is OfferCodeDiscountComputingService#once_per_cart?.
func (c *offerCode) oncePerCart() bool {
	return c.amountCents.Valid && c.flags&offerCodeOncePerCart != 0
}

// quantity is evaluate_code's: the page's, raised to the code's minimum.
func (c *offerCode) quantity(page int64) int64 {
	return max(page, c.minimumQuantity.Int64)
}

// usageUnits is usage_units at that quantity.
func (c *offerCode) usageUnits(page int64) int64 {
	if c.oncePerCart() {
		return 1
	}
	return c.quantity(page)
}

// oncePerCartCents is allocate_once_per_cart_discount for the product's own line.
func oncePerCartCents(amount, full, minPrice int64) int64 {
	allocated := min(amount, full)
	if after := full - allocated; after > 0 && after < minPrice {
		allocated = max(full-minPrice, 0)
	}
	return allocated
}

// loadOfferDiscount's price is Link#price_cents, which a once-per-cart code allocates against.
func (h *handler) loadOfferDiscount(ctx context.Context, p *page, prod *product, price *int64) (*offerDiscount, error) {
	d := &offerDiscount{}
	// auto_apply_offer_code_for.
	var auto *offerCode
	a, err := h.sellerAutoApply(p, prod)
	if err != nil {
		return nil, err
	}
	if a != nil && rails.Present(a.code.String) && a.applicable(prod) {
		auto = a
	}
	var explicit *offerCode
	if prod.defaultOfferCodeID.Valid {
		var err error
		if explicit, err = h.loadOfferCode(ctx, prod, "offer_codes.id = ? LIMIT 1", prod.defaultOfferCodeID.Int64); err != nil {
			return nil, err
		}
	}
	eff, err := h.effectiveDefault(p, prod, explicit, auto)
	if err != nil {
		return nil, err
	}
	var list []*offerCode
	if explicit != nil && explicit.existingOnly && explicit.currencyValid(prod) {
		list = append(list, explicit)
	}
	if eff != nil && eff.currencyValid(prod) && (len(list) == 0 || list[0].id != eff.id) {
		list = append(list, eff)
	}
	d.listed = len(list) > 0
	if p.quantity < 1 && (d.listed || p.discountCode != "") {
		// discount_code_props weighs the codes at this quantity, selection_discounts at one.
		return nil, fallback("param quantity")
	}
	for _, c := range list {
		if rails.Blank(c.code.String) {
			continue
		}
		valid, err := h.evaluateOfferCode(p, prod, c)
		switch {
		case err != nil:
			return nil, err
		case valid && d.code != nil:
			// best_default_code_result weighs a buyer's existing-customer default against the sale.
			return nil, fallback("offer code comparison")
		case valid:
			d.code, d.resultCode = c, c.code.String
		}
	}
	if d.urlCode = p.discountCode; d.urlCode != "" {
		if d.code != nil && strings.EqualFold(d.urlCode, d.code.code.String) {
			// The URL names the default that applies, so both would.
			return nil, fallback("offer code comparison")
		}
		fromURL, errorCode, err := h.evaluateURLCode(p, prod, d.urlCode)
		switch {
		case err != nil:
			return nil, err
		case errorCode == "" && d.code != nil:
			// met_discount_conditions? and comparison_amount weigh the two.
			return nil, fallback("offer code comparison")
		case errorCode == "":
			d.code, d.resultCode = fromURL, d.urlCode
		}
		d.urlError, d.urlRow = errorCode, fromURL
	}
	if d.code != nil && auto != nil {
		// sale_label: the winning code is the auto-applied one.
		if !permalinkParam.MatchString(auto.code.String) {
			return nil, fallback("offer code characters")
		}
		if strings.EqualFold(d.resultCode, auto.code.String) {
			d.label = auto.displayedSaleLabel()
		}
	}
	switch c := d.code; {
	case c == nil:
	case !c.universal:
		d.products, err = h.codeProductIDs(ctx, "offer_codes_products", c.id)
	case c.anyExcluded:
		d.products, err = h.codeProductIDs(ctx, "offer_codes_excluded_products", c.id)
	}
	if c := d.code; err == nil && c != nil && c.hasVariants {
		if err = h.loadCodeOptions(ctx, prod, c); err == nil && c.ownerless {
			// option_ids_by_product keys it by ObfuscateIds.encrypt(nil).
			err = fallback("offer code option product")
		}
	}
	// An invalid URL code's scope only shows on an option the applying code leaves out.
	if c := d.urlRow; err == nil && c != nil && c != d.code && c.hasVariants && (d.code == nil || len(d.code.scope) > 0) {
		err = h.loadCodeOptions(ctx, prod, c)
	}
	if c := d.code; err == nil && c != nil {
		d.cents = c.amountCents.Int64
		if c.oncePerCart() {
			cur, known := currencies[prod.productCurrency()]
			if price == nil || !known {
				return nil, fallback("once-per-cart price")
			}
			d.cents = oncePerCartCents(c.amountCents.Int64, *price*c.quantity(p.quantity), cur.minPrice)
			d.oncePerCartID = h.c.IDs.Encrypt(c.id)
		}
	}
	return d, err
}

// evaluateOfferCode is BestOfferCodeService#evaluate_code for a default code: whether it
// gives the visitor a discount. Looking c up by its string must land on c.
func (h *handler) evaluateOfferCode(p *page, prod *product, c *offerCode) (bool, error) {
	ctx, now := p.Ctx, p.Req.Now
	if reason := c.unportedLookup(prod); reason != "" {
		return false, fallback(reason)
	}
	id, err := h.findOfferCode(ctx, prod, c.code.String)
	switch {
	case err != nil || id == 0:
		return false, err
	case id != c.id:
		return false, fallback("offer code lookup")
	case !c.applicable(prod) || !c.currencyValid(prod) || c.inactive(now):
		return false, nil
	}
	if resolved, err := h.resolvesForBuyer(ctx, prod, c, p.viewer); err != nil || !resolved {
		return false, err
	}
	// Only a code that gives this buyer something has terms to read.
	if reason := c.unportedDiscount(); reason != "" {
		return false, fallback(reason)
	}
	shortfall, err := h.usesShortfall(p, c)
	return shortfall == "", err
}

// evaluateURLCode is BestOfferCodeService#evaluate_code for the URL's code: the code that
// gives the visitor a discount, else the error_code it gets, with the code when the error
// comes after the option scope.
func (h *handler) evaluateURLCode(p *page, prod *product, typed string) (*offerCode, string, error) {
	ctx, now := p.Ctx, p.Req.Now
	id, err := h.findOfferCode(ctx, prod, typed)
	if err != nil || id == 0 {
		return nil, "invalid_offer", err
	}
	c, err := h.loadOfferCode(ctx, prod, "offer_codes.id = ? LIMIT 1", id)
	switch {
	case err != nil:
		return nil, "", err
	case c == nil || !c.applicable(prod) || !c.currencyValid(prod):
		return nil, "invalid_offer", nil
	}
	if reason := c.unportedLookup(prod); reason != "" {
		return nil, "", fallback(reason)
	}
	if c.inactive(now) {
		return nil, "inactive", nil
	}
	resolved, err := h.resolvesForBuyer(ctx, prod, c, p.viewer)
	switch {
	case err != nil:
		return nil, "", err
	case !resolved && c.existingOnly:
		// A legacy code for both new and existing customers reports this one first.
		return c, "not_existing_customer", nil
	case !resolved:
		return c, "not_new_customer", nil
	}
	if reason := c.unportedDiscount(); reason != "" {
		return nil, "", fallback(reason)
	}
	if shortfall, err := h.usesShortfall(p, c); err != nil || shortfall != "" {
		return c, shortfall, err
	}
	return c, "", nil
}

// findOfferCode is find_offer_code's row for a code, 0 for none, by Rails' unordered statements.
// OfferCodeDiscountComputingService then applies the first of the seller's codes by that string
// that suits the product, in its own statement's order; any other row than this goes to Rails.
func (h *handler) findOfferCode(ctx context.Context, prod *product, code string) (int64, error) {
	code = strings.ToLower(code)
	ids, err := h.scanIDs(ctx, "SELECT `offer_codes`.* FROM `offer_codes` INNER JOIN `offer_codes_products`"+
		" ON `offer_codes`.`id` = `offer_codes_products`.`offer_code_id` WHERE `offer_codes_products`.`product_id` = ?"+
		" AND `offer_codes`.`deleted_at` IS NULL AND `offer_codes`.`code` = ? LIMIT 1", prod.id, code)
	if err == nil && len(ids) == 0 {
		// not_excluding_product binds the id into a String condition, which Rails quotes.
		ids, err = h.scanIDs(ctx, "SELECT `offer_codes`.* FROM `offer_codes` WHERE `offer_codes`.`user_id` = ?"+
			" AND (universal = 1 and (currency_type = ? or currency_type is null)) AND `offer_codes`.`deleted_at` IS NULL"+
			" AND (NOT EXISTS (SELECT 1 FROM offer_codes_excluded_products WHERE offer_codes_excluded_products.offer_code_id = offer_codes.id"+
			" AND offer_codes_excluded_products.product_id = ?)) AND `offer_codes`.`code` = ? LIMIT 1",
			prod.userID, prod.priceCurrencyType, strconv.FormatInt(prod.id, 10), code)
	}
	if err != nil || len(ids) == 0 {
		return 0, err
	}
	found := ids[0]
	if ids, err = h.scanIDs(ctx, "SELECT `offer_codes`.* FROM `offer_codes` WHERE `offer_codes`.`user_id` = ? AND `offer_codes`.`code` = ?"+
		" AND `offer_codes`.`deleted_at` IS NULL", prod.userID, code); err != nil {
		return 0, err
	}
	switch {
	case len(ids) == 1 && ids[0] == found:
		// The callers check this row's terms themselves.
		return found, nil
	case !slices.Contains(ids, found):
		// The product's code is another seller's, which the computing service never loads.
		return 0, fallback("offer code lookup")
	}
	codes, err := h.loadOfferCodes(ctx, prod, "offer_codes.id IN ("+placeholders(len(ids))+")", int64Args(ids)...)
	if err != nil {
		return 0, err
	}
	byID := make(map[int64]*offerCode, len(codes))
	for _, c := range codes {
		byID[c.id] = c
	}
	for _, id := range ids {
		if c := byID[id]; c != nil && c.applicable(prod) && c.currencyValid(prod) {
			if id != found {
				return 0, fallback("offer code lookup")
			}
			break
		}
	}
	return found, nil
}

// resultProps is the discount_code prop: the code that applies and OfferCode#discount.
func (d *offerDiscount) resultProps() any {
	c := d.code
	if c == nil {
		return invalidResult(d.urlError)
	}
	discount := rails.NewRHash()
	if c.amountCents.Valid {
		discount.Sym("type", "fixed").Sym("cents", d.cents)
	} else {
		discount.Sym("type", "percent").Sym("percents", c.amountPercentage.Int64)
	}
	var productIDs any
	if !c.universal {
		productIDs = d.products
	}
	discount.Sym("product_ids", productIDs).
		Sym("expires_at", c.expiresAt.OrNil()).
		Sym("minimum_quantity", nullInt(c.minimumQuantity)).
		Sym("duration_in_billing_cycles", nullInt(c.durationInMonths)).
		Sym("minimum_amount_cents", nullInt(c.minimumAmountCents))
	if c.universal && len(d.products) > 0 {
		discount.Sym("excluded_product_ids", d.products)
	}
	if c.optionIDs != nil {
		discount.Sym("option_ids_by_product", c.optionIDs)
	}
	if c.newOnly {
		// Display only; checkout decides.
		discount.Sym("new_customers_only", true)
	}
	if c.oncePerCart() {
		discount.Sym("once_per_cart", true).Sym("once_per_cart_id", d.oncePerCartID).
			Sym("once_per_cart_amount_cents", c.amountCents.Int64).Sym("once_per_cart_has_usage_limit", c.maxPurchaseCount.Valid)
	}
	return rails.NewRHash().Sym("valid", true).Sym("code", d.resultCode).Sym("discount", discount)
}

// selectionDiscounts is selection_discounts. With no code in the URL and no default code it
// has no options; otherwise each option the buyer can pick, rented or bought, gets the one
// result, as only one code can apply, unless the option is outside that code's scope.
func selectionDiscounts(p *page, prod *product, v *view, result any) *rails.RHash {
	urlCode := presence(v.discount.urlCode)
	s := rails.NewRHash().Sym("url_code", urlCode).Sym("quantity", max(p.quantity, 1)).Sym("recurrence", v.recurrences.defaultRecurrence()).
		Sym("option_id", nil).Sym("price_cents", nil)
	if !v.discount.listed && urlCode == nil {
		return s.Sym("options", rails.NewRHash()).Sym("rent_options", nil)
	}
	quotes := func() *rails.RHash {
		out := rails.NewRHash()
		if len(v.variants.options) == 0 {
			return out.Str("", v.discount.optionEntry(nil, result))
		}
		for _, o := range v.variants.options {
			// cart_item prices another option in a closed tier's place.
			if !o.closed {
				out.Str(o.externalID, v.discount.optionEntry(o, result))
			}
		}
		return out
	}
	var rentOptions any
	if v.prices.rental != nil && !prod.rentOnly() {
		rentOptions = quotes()
	}
	return s.Sym("options", quotes()).Sym("rent_options", rentOptions)
}

// optionEntry is an option's quote: BestOfferCodeService#result with that option. The computing
// service drops an option outside the code's scope before its buyer and usage checks, so the URL
// code then says option_not_eligible and a default gives nothing.
func (d *offerDiscount) optionEntry(o *variantOption, result any) *rails.RHash {
	entry := rails.NewRHash()
	switch {
	case d.code != nil && !d.code.excludes(o):
		return entry.Sym("discount_code", result).Sym("sale_label", d.label)
	case d.urlRow != nil && d.urlRow.excludes(o):
		entry.Sym("discount_code", invalidResult("option_not_eligible"))
	default:
		entry.Sym("discount_code", invalidResult(d.urlError))
	}
	return entry.Sym("sale_label", nil)
}

// invalidResult is an invalid result's error_code, nil without one.
func invalidResult(errorCode string) any {
	if errorCode == "" {
		return nil
	}
	return rails.NewRHash().Sym("valid", false).Sym("error_code", errorCode)
}

// discountedCents is discounted_price_cents at the page's quantity.
func (d *offerDiscount) discountedCents(price, quantity int64) int64 {
	c := d.code
	if c == nil || c.minimumQuantity.Int64 > quantity {
		return price
	}
	if c.amountCents.Valid {
		return max(price-d.cents, 0)
	}
	return price - c.amountOff(price)
}
