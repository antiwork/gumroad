package products

import (
	"database/sql"
	"fmt"
	"maps"
	"strings"
	"testing"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/pages"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
)

// How a signed-in buyer's purchases decide the codes for new or existing customers, read
// through the evaluators the product page calls.
func TestABuyersPurchasesDecideCustomerCodes(t *testing.T) {
	const buyerID, codeID, otherID = int64(1_797_001), int64(1_797_101), int64(1_797_201)
	confirmed := &signedInUser{user: user{id: buyerID}, email: sql.NullString{String: "buyer@example.com", Valid: true},
		confirmedAt: db.NullTime{Time: testNow, Valid: true}}
	unconfirmed := &signedInUser{user: user{id: buyerID}, email: confirmed.email}
	blank := &signedInUser{user: user{id: buyerID}, email: sql.NullString{Valid: true}, confirmedAt: confirmed.confirmedAt}
	purchase := func(t *testing.T, conn *sql.DB, id int64, columns map[string]any) {
		row := map[string]any{"id": id, "seller_id": sellerID, "link_id": productID, "purchaser_id": buyerID,
			"email": "buyer@example.com", "purchase_state": "successful", "created_at": testNow.AddDate(0, -2, 0), "updated_at": testNow}
		maps.Copy(row, columns)
		testdb.Insert(t, conn, "purchases", row)
	}
	code := func(t *testing.T, conn *sql.DB, columns map[string]any) {
		row := map[string]any{"code": "LOYAL", "amount_percentage": 10, "universal": true}
		maps.Copy(row, columns)
		insertOfferCode(t, conn, codeID, row)
	}
	existing := map[string]any{"existing_customers_only": true}
	fresh := map[string]any{"new_customers_only": true}
	for _, c := range []struct {
		name  string
		buyer *signedInUser
		code  map[string]any
		setup func(t *testing.T, conn *sql.DB)
		// errorCode is the URL code's, "" when it applies; the default code applies just when it is.
		errorCode string
	}{
		{name: "signed out, for existing customers", code: existing, errorCode: "not_existing_customer"},
		{name: "signed out, for new customers", code: fresh},
		{name: "a buyer of the product", buyer: confirmed, code: existing,
			setup: func(t *testing.T, conn *sql.DB) { purchase(t, conn, 1_797_301, nil) }},
		{name: "a buyer with no purchase", buyer: confirmed, code: existing, errorCode: "not_existing_customer"},
		{name: "a purchase under the account with another email", buyer: unconfirmed, code: existing,
			setup: func(t *testing.T, conn *sql.DB) {
				purchase(t, conn, 1_797_301, map[string]any{"email": "other@example.com"})
			}},
		{name: "a blank email matches no guest purchase", buyer: blank, code: existing, errorCode: "not_existing_customer",
			setup: func(t *testing.T, conn *sql.DB) {
				purchase(t, conn, 1_797_301, map[string]any{"purchaser_id": nil, "email": ""})
			}},
		{name: "a code that has ended", buyer: confirmed, code: map[string]any{"existing_customers_only": true, "expires_at": testNow},
			errorCode: "inactive", setup: func(t *testing.T, conn *sql.DB) { purchase(t, conn, 1_797_301, nil) }},
		// A tiered code the buyer doesn't qualify for has no terms to read.
		{name: "a tiered code for a buyer with no purchase", buyer: confirmed, code: map[string]any{"existing_customers_only": true,
			"ownership_duration_tiers": `[{"months":12,"amount_percentage":20}]`}, errorCode: "not_existing_customer"},
		{name: "a gift's receiver on a renewing subscription", buyer: confirmed, code: existing, setup: func(t *testing.T, conn *sql.DB) {
			purchase(t, conn, 1_797_301, map[string]any{"subscription_id": 1_797_401, "flags": purchaseIsGiftReceiver})
		}},
		{name: "a guest purchase under the confirmed email", buyer: confirmed, code: existing,
			setup: func(t *testing.T, conn *sql.DB) { purchase(t, conn, 1_797_301, map[string]any{"purchaser_id": nil}) }},
		// An unconfirmed address hasn't been proven to be the buyer's.
		{name: "a guest purchase under an unconfirmed email", buyer: unconfirmed, code: existing, errorCode: "not_existing_customer",
			setup: func(t *testing.T, conn *sql.DB) { purchase(t, conn, 1_797_301, map[string]any{"purchaser_id": nil}) }},
		{name: "a refunded purchase", buyer: confirmed, code: existing, errorCode: "not_existing_customer",
			setup: func(t *testing.T, conn *sql.DB) {
				purchase(t, conn, 1_797_301, map[string]any{"stripe_refunded": true})
			}},
		{name: "a chargeback", buyer: confirmed, code: existing, errorCode: "not_existing_customer",
			setup: func(t *testing.T, conn *sql.DB) {
				purchase(t, conn, 1_797_301, map[string]any{"chargeback_date": testNow})
			}},
		{name: "a reversed chargeback", buyer: confirmed, code: existing, setup: func(t *testing.T, conn *sql.DB) {
			purchase(t, conn, 1_797_301, map[string]any{"chargeback_date": testNow, "flags": purchaseChargebackReversed})
		}},
		{name: "a renewal charge", buyer: confirmed, code: existing, errorCode: "not_existing_customer",
			setup: func(t *testing.T, conn *sql.DB) {
				purchase(t, conn, 1_797_301, map[string]any{"subscription_id": 1_797_401})
			}},
		{name: "an original subscription purchase", buyer: confirmed, code: existing, setup: func(t *testing.T, conn *sql.DB) {
			purchase(t, conn, 1_797_301, map[string]any{"subscription_id": 1_797_401, "flags": purchaseIsOriginalSubscription})
		}},
		{name: "a failed purchase", buyer: confirmed, code: existing, errorCode: "not_existing_customer",
			setup: func(t *testing.T, conn *sql.DB) {
				purchase(t, conn, 1_797_301, map[string]any{"purchase_state": "failed"})
			}},
		{name: "revoked access", buyer: confirmed, code: existing, errorCode: "not_existing_customer",
			setup: func(t *testing.T, conn *sql.DB) {
				purchase(t, conn, 1_797_301, map[string]any{"flags": purchaseIsAccessRevoked})
			}},
		// pick(:created_at) takes the oldest, and MySQL sorts NULL first.
		{name: "an oldest purchase without a date", buyer: confirmed, code: existing, errorCode: "not_existing_customer",
			setup: func(t *testing.T, conn *sql.DB) {
				purchase(t, conn, 1_797_301, nil)
				purchase(t, conn, 1_797_302, map[string]any{"created_at": nil})
			}},
		// ownership_products, when there are any, are what counts.
		{name: "the code's ownership product", buyer: confirmed, code: existing, setup: func(t *testing.T, conn *sql.DB) {
			insertOwnershipProduct(t, conn, codeID, otherID)
			purchase(t, conn, 1_797_301, map[string]any{"link_id": otherID})
		}},
		{name: "this product beside an ownership product", buyer: confirmed, code: existing, errorCode: "not_existing_customer",
			setup: func(t *testing.T, conn *sql.DB) {
				insertOwnershipProduct(t, conn, codeID, otherID)
				purchase(t, conn, 1_797_301, nil)
			}},
		{name: "a new customer", buyer: confirmed, code: fresh},
		// returning_customer? reads any of the seller's products, and the email confirmed or not.
		{name: "a returning customer", buyer: unconfirmed, code: fresh, errorCode: "not_new_customer",
			setup: func(t *testing.T, conn *sql.DB) {
				purchase(t, conn, 1_797_301, map[string]any{"purchaser_id": nil, "link_id": otherID})
			}},
		{name: "a returning customer by account", buyer: confirmed, code: fresh, errorCode: "not_new_customer",
			setup: func(t *testing.T, conn *sql.DB) {
				purchase(t, conn, 1_797_301, map[string]any{"email": "other@example.com", "link_id": otherID})
			}},
		{name: "a blank email matches no guest purchase from the seller", buyer: blank, code: fresh,
			setup: func(t *testing.T, conn *sql.DB) {
				purchase(t, conn, 1_797_301, map[string]any{"purchaser_id": nil, "email": ""})
			}},
		// not_new_customer outranks sold_out.
		{name: "a sold-out code for a returning customer", buyer: confirmed, code: map[string]any{"new_customers_only": true,
			"max_purchase_count": 1}, errorCode: "not_new_customer", setup: func(t *testing.T, conn *sql.DB) {
			purchase(t, conn, 1_797_301, map[string]any{"offer_code_id": codeID})
		}},
		{name: "a legacy code for new and existing customers", buyer: confirmed,
			code: map[string]any{"new_customers_only": true, "existing_customers_only": true}, errorCode: "not_existing_customer",
			setup: func(t *testing.T, conn *sql.DB) { purchase(t, conn, 1_797_301, nil) }},
		{name: "a customer of another seller", buyer: confirmed, code: fresh,
			setup: func(t *testing.T, conn *sql.DB) { purchase(t, conn, 1_797_301, map[string]any{"seller_id": 1_797_501}) }},
		{name: "a gift's sender", buyer: confirmed, code: fresh,
			setup: func(t *testing.T, conn *sql.DB) {
				purchase(t, conn, 1_797_301, map[string]any{"flags": purchaseIsGiftSender})
			}},
		{name: "an additional contribution", buyer: confirmed, code: fresh, setup: func(t *testing.T, conn *sql.DB) {
			purchase(t, conn, 1_797_301, map[string]any{"flags": purchaseIsAdditionalContribution})
		}},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			conn := testdb.Open(t)
			h := &handler{c: e.config}
			code(t, conn, c.code)
			if c.setup != nil {
				c.setup(t, conn)
			}
			prod := &product{id: productID, userID: sellerID, priceCurrencyType: sql.NullString{String: "usd", Valid: true}}
			p := &page{Visit: &pages.Visit{Ctx: t.Context(), Req: &rails.Request{Now: testNow.Add(time.Hour)}}, viewer: c.buyer}
			fromURL, errorCode, err := h.evaluateURLCode(p, prod, "loyal")
			// The code comes back with any error the option scope can override.
			codeLevel := c.errorCode == "invalid_offer" || c.errorCode == "inactive"
			if err != nil || errorCode != c.errorCode || (fromURL == nil) != codeLevel {
				t.Errorf("URL code: %v %q %v, want %q", fromURL != nil, errorCode, err, c.errorCode)
			}
			stored, err := h.loadOfferCode(t.Context(), prod, "offer_codes.id = ? LIMIT 1", codeID)
			if err != nil {
				t.Fatal(err)
			}
			if valid, err := h.evaluateOfferCode(p, prod, stored); err != nil || (valid != nil) != (c.errorCode == "") {
				t.Errorf("default code: %v %v, want %v", valid, err, c.errorCode == "")
			}
		})
	}
}

// An option the buyer must have purchased is left to Rails, which reads the purchase's options:
// owning another option of the product doesn't make the code apply here.
func TestAnOwnershipOptionFallsBackToRails(t *testing.T) {
	const codeID = int64(1_797_102)
	buyer := &signedInUser{user: user{id: 1_797_002}}
	want := fallback("offer code ownership variants")
	e := newTestEnv(t)
	conn := testdb.Open(t)
	h := &handler{c: e.config}
	insertOfferCode(t, conn, codeID, map[string]any{"code": "LOYAL", "amount_percentage": 10, "universal": true,
		"existing_customers_only": true})
	testdb.Insert(t, conn, "offer_codes_ownership_variants", map[string]any{"id": int64(1_797_611), "offer_code_id": codeID,
		"variant_id": int64(1_797_621), "created_at": testNow, "updated_at": testNow})
	testdb.Insert(t, conn, "purchases", map[string]any{"id": int64(1_797_311), "seller_id": sellerID, "link_id": productID,
		"purchaser_id": buyer.id, "purchase_state": "successful", "created_at": testNow, "updated_at": testNow})
	prod := &product{id: productID, userID: sellerID, priceCurrencyType: sql.NullString{String: "usd", Valid: true}}
	p := &page{Visit: &pages.Visit{Ctx: t.Context(), Req: &rails.Request{Now: testNow.Add(time.Hour)}}, viewer: buyer}
	if _, _, err := h.evaluateURLCode(p, prod, "loyal"); err != want {
		t.Errorf("URL code: %v, want the fallback", err)
	}
	stored, err := h.loadOfferCode(t.Context(), prod, "offer_codes.id = ? LIMIT 1", codeID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.evaluateOfferCode(p, prod, stored); err != want {
		t.Errorf("default code: %v, want the fallback", err)
	}
}

// A buyer can make the product's existing-customer default apply, which best_default_code_result
// then weighs against the sale: the sale only wins by taking more off.
func TestABuyersExistingCustomerDefault(t *testing.T) {
	const loyalID, saleID = int64(1_797_111), int64(1_797_112)
	buyer := &signedInUser{user: user{id: 1_797_001}}
	for _, c := range []struct {
		name, reason, code string
		sale               int
	}{
		{name: "alone", code: "loyal"},
		{name: "beside a bigger sale", sale: 20, code: "sale"},
		{name: "beside a sale as big", sale: 10, code: "loyal"},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			conn := testdb.Open(t)
			h := &handler{c: e.config}
			insertOfferCode(t, conn, loyalID, map[string]any{"code": "loyal", "amount_percentage": 10, "existing_customers_only": true})
			testdb.Insert(t, conn, "offer_codes_products", map[string]any{"id": int64(1_797_121), "offer_code_id": loyalID, "product_id": productID})
			if c.sale > 0 {
				insertOfferCode(t, conn, saleID, map[string]any{"code": "sale", "amount_percentage": c.sale, "universal": true, "auto_apply": true})
			}
			testdb.Insert(t, conn, "purchases", map[string]any{"id": int64(1_797_301), "seller_id": sellerID, "link_id": productID,
				"purchaser_id": buyer.id, "purchase_state": "successful", "created_at": testNow, "updated_at": testNow})
			p := &page{Visit: &pages.Visit{Ctx: t.Context(), Req: &rails.Request{Now: testNow.Add(time.Hour)}}, seller: &user{id: sellerID},
				viewer: buyer, hasAutoApplyCode: c.sale > 0}
			prod := &product{id: productID, userID: sellerID, priceCurrencyType: sql.NullString{String: "usd", Valid: true},
				defaultOfferCodeID: sql.NullInt64{Int64: loyalID, Valid: true}}
			v := &view{}
			var err error
			if v.prices, err = h.loadPrices(t.Context(), prod); err != nil {
				t.Fatal(err)
			}
			if v.variants, err = h.loadVariants(t.Context(), prod); err != nil {
				t.Fatal(err)
			}
			v.priceCents = v.prices.buy
			d, err := h.loadOfferDiscount(t.Context(), p, prod, v)
			switch {
			case c.reason != "":
				if err != fallback(c.reason) {
					t.Fatalf("got %v, want the %q fallback", err, c.reason)
				}
			case err != nil || d.code == nil || d.resultCode != c.code:
				t.Fatalf("got %v, %+v", err, d)
			}
		})
	}
}

// insertOwnershipProduct makes product one of the code's ownership_products.
func insertOwnershipProduct(t *testing.T, conn *sql.DB, code, product int64) {
	testdb.Insert(t, conn, "links", map[string]any{"id": product, "user_id": sellerID, "name": "Other", "unique_permalink": "gowebown",
		"price_cents": 100, "created_at": testNow, "updated_at": testNow})
	testdb.Insert(t, conn, "offer_codes_ownership_products", map[string]any{"id": int64(1_797_601), "offer_code_id": code, "product_id": product,
		"created_at": testNow, "updated_at": testNow})
}

// A signed-in buyer's tiered code takes the tier their oldest qualifying purchase reaches.
func TestATieredCodeForABuyer(t *testing.T) {
	const codeID = int64(1_797_131)
	for _, c := range []struct {
		name  string
		owned bool
		want  int64
	}{
		{name: "a buyer of 13 months", owned: true, want: 25},
		{name: "a buyer who never bought it", want: 10},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			conn := testdb.Open(t)
			h := &handler{c: e.config}
			buyer := &signedInUser{user: user{id: 1_797_002}}
			now := testNow.Add(time.Hour)
			insertOfferCode(t, conn, codeID, map[string]any{"code": "LOYAL", "universal": true,
				"ownership_duration_tiers": `[{"months":0,"amount_percentage":10},{"months":12,"amount_percentage":25}]`})
			if c.owned {
				testdb.Insert(t, conn, "purchases", map[string]any{"id": int64(1_797_311), "seller_id": sellerID, "link_id": productID,
					"purchaser_id": buyer.id, "purchase_state": "successful", "created_at": now.AddDate(0, -13, 0), "updated_at": now})
			}
			p := &page{Visit: &pages.Visit{Ctx: t.Context(), Req: &rails.Request{Now: now}}, seller: &user{id: sellerID}, viewer: buyer}
			p.discountCode = "LOYAL"
			prod := &product{id: productID, userID: sellerID, priceCurrencyType: sql.NullString{String: "usd", Valid: true}}
			v := &view{}
			var err error
			if v.prices, err = h.loadPrices(t.Context(), prod); err != nil {
				t.Fatal(err)
			}
			if v.variants, err = h.loadVariants(t.Context(), prod); err != nil {
				t.Fatal(err)
			}
			v.priceCents = v.prices.buy
			d, err := h.loadOfferDiscount(t.Context(), p, prod, v)
			if err != nil || d.code == nil || d.code.amountPercentage.Int64 != c.want || d.resultCode != "LOYAL" {
				t.Fatalf("got %v, %+v", err, d)
			}
		})
	}
}

// The buyer's tier lands on the product's own copy of the seller's sale: the shared code, which
// cards read, keeps the percentage it stores.
func TestATieredSaleKeepsItsStoredPercentage(t *testing.T) {
	const codeID = int64(1_797_132)
	e := newTestEnv(t)
	conn := testdb.Open(t)
	h := &handler{c: e.config}
	buyer := &signedInUser{user: user{id: 1_797_003}}
	now := testNow.Add(time.Hour)
	insertOfferCode(t, conn, codeID, map[string]any{"code": "SALE", "amount_percentage": 10, "universal": true, "auto_apply": true,
		"ownership_duration_tiers": `[{"months":0,"amount_percentage":10},{"months":12,"amount_percentage":25}]`})
	testdb.Insert(t, conn, "purchases", map[string]any{"id": int64(1_797_312), "seller_id": sellerID, "link_id": productID,
		"purchaser_id": buyer.id, "purchase_state": "successful", "created_at": now.AddDate(0, -13, 0), "updated_at": now})
	p := &page{Visit: &pages.Visit{Ctx: t.Context(), Req: &rails.Request{Now: now}}, seller: &user{id: sellerID}, viewer: buyer,
		hasAutoApplyCode: true}
	prod := &product{id: productID, userID: sellerID, priceCurrencyType: sql.NullString{String: "usd", Valid: true}}
	v := &view{}
	var err error
	if v.prices, err = h.loadPrices(t.Context(), prod); err != nil {
		t.Fatal(err)
	}
	if v.variants, err = h.loadVariants(t.Context(), prod); err != nil {
		t.Fatal(err)
	}
	v.priceCents = v.prices.buy
	d, err := h.loadOfferDiscount(t.Context(), p, prod, v)
	if err != nil || d.code == nil || d.code.amountPercentage.Int64 != 25 {
		t.Fatalf("got %v, %+v", err, d)
	}
	if p.autoApply == nil || p.autoApply.amountPercentage != (sql.NullInt64{Int64: 10, Valid: true}) {
		t.Errorf("the seller's sale is now %+v", p.autoApply)
	}
}

// Each selection_discounts entry weighs the codes at its own price, so the URL's code, a buyer's
// existing-customer default and the sale can each win one: $1.50 off at 500 cents, $3 off past
// a 900-cent minimum at 1,000, and 20% at 2,000.
func TestThreeCodesEachWinningAnOption(t *testing.T) {
	const urlID, loyalID, saleID = int64(1_797_141), int64(1_797_142), int64(1_797_143)
	const category, small, mid, large = int64(1_797_151), int64(1_797_152), int64(1_797_153), int64(1_797_154)
	e := newTestEnv(t)
	conn := testdb.Open(t)
	h := &handler{c: e.config}
	buyer := &signedInUser{user: user{id: 1_797_003}}
	insertOfferCode(t, conn, urlID, map[string]any{"code": "SAVE", "amount_cents": 150, "currency_type": "usd", "universal": true})
	insertOfferCode(t, conn, loyalID, map[string]any{"code": "loyal", "amount_cents": 300, "currency_type": "usd", "minimum_amount_cents": 900,
		"existing_customers_only": true})
	testdb.Insert(t, conn, "offer_codes_products", map[string]any{"id": int64(1_797_161), "offer_code_id": loyalID, "product_id": productID})
	insertOfferCode(t, conn, saleID, map[string]any{"code": "SALE", "amount_percentage": 20, "universal": true, "auto_apply": true})
	testdb.Insert(t, conn, "purchases", map[string]any{"id": int64(1_797_321), "seller_id": sellerID, "link_id": productID,
		"purchaser_id": buyer.id, "purchase_state": "successful", "created_at": testNow, "updated_at": testNow})
	testdb.Insert(t, conn, "variant_categories", map[string]any{"id": category, "link_id": productID, "title": "Size"})
	for i, id := range []int64{small, mid, large} {
		testdb.Insert(t, conn, "base_variants", map[string]any{"id": id, "type": "Variant", "variant_category_id": category, "name": fmt.Sprint("Size ", i),
			"position_in_category": i, "price_difference_cents": []int{0, 500, 1500}[i], "created_at": testNow, "updated_at": testNow})
	}
	p := &page{Visit: &pages.Visit{Ctx: t.Context(), Req: &rails.Request{Now: testNow.Add(time.Hour)}}, seller: &user{id: sellerID},
		viewer: buyer, hasAutoApplyCode: true}
	p.discountCode = "SAVE"
	prod := &product{id: productID, userID: sellerID, priceCurrencyType: sql.NullString{String: "usd", Valid: true},
		defaultOfferCodeID: sql.NullInt64{Int64: loyalID, Valid: true}}
	v := &view{}
	var err error
	if v.prices, err = h.loadPrices(t.Context(), prod); err != nil {
		t.Fatal(err)
	}
	if v.variants, err = h.loadVariants(t.Context(), prod); err != nil {
		t.Fatal(err)
	}
	v.priceCents = v.prices.buy
	if v.discount, err = h.loadOfferDiscount(t.Context(), p, prod, v); err != nil {
		t.Fatal(err)
	}
	if v.discount.resultCode != "SAVE" {
		t.Errorf("the page's code %q", v.discount.resultCode)
	}
	options := rails.EncodeJSON(selectionDiscounts(p, prod, v, v.discount.resultProps()))
	for id, want := range map[int64]string{
		small: `{"discount_code":{"valid":true,"code":"SAVE","discount":{"type":"fixed","cents":150,`,
		mid:   `{"discount_code":{"valid":true,"code":"loyal","discount":{"type":"fixed","cents":300,`,
		large: `{"discount_code":{"valid":true,"code":"SALE","discount":{"type":"percent","percents":20,`,
	} {
		if entry := `"` + e.ids.Encrypt(id) + `":` + want; !strings.Contains(options, entry) {
			t.Errorf("want %s in %s", entry, options)
		}
	}
	if !strings.Contains(options, `"sale_label":"Sale"}`) || strings.Count(options, `"sale_label":null`) != 2 {
		t.Errorf("labels in %s", options)
	}
}
