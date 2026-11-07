package products

import (
	"context"
	"database/sql"
	"fmt"
	"html"
	"maps"
	"net/http"
	"net/url"
	"strings"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/pages"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
)

const browserGUID = "0b4c5d6e-browser"

func addPurchase(t *testing.T, conn *sql.DB, id int64, columns map[string]any) {
	row := map[string]any{"id": id, "link_id": productID, "seller_id": sellerID, "price_cents": 500, "total_transaction_cents": 500,
		"gumroad_tax_cents": 0, "purchase_state": "successful", "email": "buyer@example.com", "displayed_price_currency_type": "usd",
		"created_at": testNow, "updated_at": testNow}
	for k, v := range columns {
		row[k] = v
	}
	testdb.Insert(t, conn, "purchases", row)
}

// purchaseHead is the purchase prop up to review_account_name's value.
func purchaseHead(e *testEnv, id int64, email string) string {
	return fmt.Sprintf(`"purchase":{"id":"%s","email_digest":"%s","created_at":"2026-11-06T12:00:00Z",`, e.ids.Encrypt(id),
		rails.EmailDigest(e.config.Page.EmailDigestKey, id, email))
}

// The page shows the visitor's own purchase of the product, else the last one this browser made
// signed out, among those still standing.
func TestAVisitorsPurchase(t *testing.T) {
	guidCookie := map[string]string{"Cookie": "_gumroad_guid=" + browserGUID}
	for _, c := range []struct {
		name     string
		signedIn bool
		setup    func(t *testing.T, conn *sql.DB)
		want     func(e *testEnv) string
	}{
		{name: "this browser's, past a refund, a chargeback, a tip and a gift", setup: func(t *testing.T, conn *sql.DB) {
			addPurchase(t, conn, 1_797_701, map[string]any{"browser_guid": browserGUID})
			testdb.Insert(t, conn, "url_redirects", map[string]any{"id": int64(1_797_711), "purchase_id": int64(1_797_701), "token": "tok701",
				"created_at": testNow, "updated_at": testNow})
			addPurchase(t, conn, 1_797_702, map[string]any{"browser_guid": browserGUID, "stripe_refunded": true})
			addPurchase(t, conn, 1_797_703, map[string]any{"browser_guid": browserGUID, "chargeback_date": testNow})
			addPurchase(t, conn, 1_797_704, map[string]any{"browser_guid": browserGUID, "flags": purchaseIsAdditionalContribution})
			addPurchase(t, conn, 1_797_705, map[string]any{"browser_guid": browserGUID, "flags": purchaseIsGiftSender})
			addPurchase(t, conn, 1_797_706, map[string]any{"browser_guid": browserGUID, "flags": purchaseIsGiftReceiver,
				"purchase_state": "gift_receiver_purchase_successful"})
			addPurchase(t, conn, 1_797_707, map[string]any{"browser_guid": browserGUID, "purchaser_id": buyerID})
		}, want: func(e *testEnv) string {
			return purchaseHead(e, 1_797_701, "buyer@example.com") + `"review":null,"review_account_name":null,"should_show_receipt":true,` +
				`"was_paid":true,"is_gift_receiver_purchase":false,"show_view_content_button_on_product_page":true,` +
				`"total_price_including_tax_and_shipping":"$5","content_url":"` + e.config.Env.Protocol + "://" + e.config.Env.Domain +
				`/d/tok701","subscription_has_lapsed":false,"membership":null,"license_key":null}`
		}},
		{name: "an expired rental", setup: func(t *testing.T, conn *sql.DB) {
			addPurchase(t, conn, 1_797_701, map[string]any{"browser_guid": browserGUID, "rental_expired": true})
		}, want: func(*testEnv) string { return `"purchase":null` }},
		// Theirs wins over the browser's, here in euros at the rate it was bought at, with its review.
		{name: "the visitor's own", signedIn: true, setup: func(t *testing.T, conn *sql.DB) {
			addPurchase(t, conn, 1_797_701, map[string]any{"browser_guid": browserGUID})
			addPurchase(t, conn, 1_797_702, map[string]any{"purchaser_id": buyerID, "displayed_price_currency_type": "eur",
				"rate_converted_to_usd": "0.92", "total_transaction_cents": 1_000, "price_cents": 0, "offer_code_id": int64(1)})
			testdb.Insert(t, conn, "product_reviews", map[string]any{"id": int64(1_797_721), "purchase_id": int64(1_797_702), "link_id": productID,
				"rating": 4, "message": "Good", "anonymous": true, "created_at": testNow, "updated_at": testNow})
		}, want: func(e *testEnv) string {
			return purchaseHead(e, 1_797_702, "buyer@example.com") + `"review":{"anonymous":true,"rating":4,"message":"Good","video":null},` +
				`"review_account_name":"Buyer","should_show_receipt":true,"was_paid":true,"is_gift_receiver_purchase":false,` +
				`"show_view_content_button_on_product_page":false,"total_price_including_tax_and_shipping":"€9.20","content_url":null,` +
				`"subscription_has_lapsed":false,"membership":null,"license_key":null}`
		}},
		// Any purchase of theirs keeps the browser's out, even one that failed.
		{name: "the visitor's failed one", signedIn: true, setup: func(t *testing.T, conn *sql.DB) {
			addPurchase(t, conn, 1_797_701, map[string]any{"browser_guid": browserGUID})
			addPurchase(t, conn, 1_797_702, map[string]any{"purchaser_id": buyerID, "purchase_state": "failed"})
		}, want: func(*testEnv) string { return `"purchase":null` }},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			conn := testdb.Open(t)
			addBuyer(t, conn, nil)
			c.setup(t, conn)
			headers := guidCookie
			if c.signedIn {
				headers = e.signedIn(buyerID, nil)
				headers["Cookie"] += "; _gumroad_guid=" + browserGUID
			}
			w := e.get(host, "/l/guide", headers)
			if w.Code != http.StatusOK || e.railsHit != nil {
				t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
			}
			page := html.UnescapeString(dataPage.FindStringSubmatch(w.Body.String())[1])
			if want := c.want(e); !strings.Contains(page, want) {
				t.Errorf("want %s\nin %s", want, page)
			}
		})
	}
}

// A purchase whose info this port doesn't build goes to Rails.
func TestAVisitorsPurchaseGoesToRails(t *testing.T) {
	for _, c := range []struct {
		name, reason string
		setup        func(t *testing.T, conn *sql.DB)
	}{
		{"a gift", "gift purchase", func(t *testing.T, conn *sql.DB) {
			addPurchase(t, conn, 1_797_801, map[string]any{"purchaser_id": buyerID, "flags": purchaseIsGiftReceiver,
				"purchase_state": "gift_receiver_purchase_successful"})
		}},
		{"a price in the buyer's currency", "purchase presentment or shipment", func(t *testing.T, conn *sql.DB) {
			addPurchase(t, conn, 1_797_801, map[string]any{"purchaser_id": buyerID})
			testdb.Insert(t, conn, "purchase_presentments", map[string]any{"id": int64(1_797_811), "purchase_id": int64(1_797_801),
				"processor": "stripe", "presentment_currency": "cad", "presentment_price_cents": 650, "presentment_total_cents": 650,
				"presentment_gumroad_amount_cents": 0, "created_at": testNow, "updated_at": testNow})
		}},
		{"a license key", "purchase license key", func(t *testing.T, conn *sql.DB) {
			mustExec(t, conn, "UPDATE links SET flags = flags | ? WHERE id = ?", productIsLicensed, productID)
			addPurchase(t, conn, 1_797_801, map[string]any{"purchaser_id": buyerID})
			testdb.Insert(t, conn, "licenses", map[string]any{"id": int64(1_797_811), "link_id": productID, "purchase_id": int64(1_797_801),
				"serial": "ABC", "created_at": testNow, "updated_at": testNow})
		}},
		{"a review video", "purchase review video", func(t *testing.T, conn *sql.DB) {
			addPurchase(t, conn, 1_797_801, map[string]any{"purchaser_id": buyerID})
			testdb.Insert(t, conn, "product_reviews", map[string]any{"id": int64(1_797_811), "purchase_id": int64(1_797_801), "link_id": productID,
				"rating": 5, "created_at": testNow, "updated_at": testNow})
			testdb.Insert(t, conn, "product_review_videos", map[string]any{"id": int64(1_797_812), "product_review_id": int64(1_797_811),
				"approval_status": "pending_review", "created_at": testNow, "updated_at": testNow})
		}},
		// purchase_info compares these in keys the page doesn't show.
		{"a NULL shipping amount", "purchase amounts", func(t *testing.T, conn *sql.DB) {
			addPurchase(t, conn, 1_797_801, map[string]any{"purchaser_id": buyerID, "shipping_cents": nil})
		}},
		{"a NULL Gumroad tax on an untaxed purchase", "purchase amounts", func(t *testing.T, conn *sql.DB) {
			addPurchase(t, conn, 1_797_801, map[string]any{"purchaser_id": buyerID, "gumroad_tax_cents": nil})
		}},
		{"another seller's row", "purchase seller", func(t *testing.T, conn *sql.DB) {
			addPurchase(t, conn, 1_797_801, map[string]any{"purchaser_id": buyerID, "seller_id": nil})
		}},
		{"a tax rate without its rate", "purchase tax rate", func(t *testing.T, conn *sql.DB) {
			testdb.Insert(t, conn, "zip_tax_rates", map[string]any{"id": int64(1_797_831), "country": "DE", "created_at": testNow,
				"updated_at": testNow})
			addPurchase(t, conn, 1_797_801, map[string]any{"purchaser_id": buyerID, "zip_tax_rate_id": int64(1_797_831),
				"flags": purchaseWasTaxable})
		}},
		{"a currency this port can't convert", "purchase currency", func(t *testing.T, conn *sql.DB) {
			addPurchase(t, conn, 1_797_801, map[string]any{"purchaser_id": buyerID, "displayed_price_currency_type": "eur"})
		}},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			conn := testdb.Open(t)
			addBuyer(t, conn, nil)
			c.setup(t, conn)
			headers := e.withDryRun("/l/guide", e.signedIn(buyerID, nil), c.reason)
			w := e.get(host, "/l/guide", headers)
			if w.Code != http.StatusNoContent || w.Header().Get("X-Go-Web-Fallback") != c.reason {
				t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
			}
		})
	}
}

// formatted_total_transaction_amount adds price_for_recurrence's recurrence, the purchase's
// price or its subscription's last payment option's, or "once" for a subscription that charges once.
// has_one :url_redirect's unordered statement takes the row MySQL's plan returns, here the lower
// id's.
func TestAPurchaseWithTwoDownloadLinks(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	addBuyer(t, conn, nil)
	addPurchase(t, conn, 1_797_801, map[string]any{"purchaser_id": buyerID})
	for i := range int64(2) {
		testdb.Insert(t, conn, "url_redirects", map[string]any{"id": 1_797_821 + i, "purchase_id": int64(1_797_801),
			"token": fmt.Sprintf("tok%d", i), "created_at": testNow, "updated_at": testNow})
	}
	w := e.get(host, "/l/guide", e.signedIn(buyerID, nil))
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	want := `"content_url":"` + e.config.Env.Protocol + "://" + e.config.Env.Domain + `/d/tok0"`
	if !strings.Contains(html.UnescapeString(w.Body.String()), want) {
		t.Errorf("want %s", want)
	}
}

func TestAPurchasesFormattedTotal(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	h := &handler{c: e.config}
	p := &page{Visit: &pages.Visit{Ctx: context.Background()}}
	price := func(id int64, recurrence any) {
		testdb.Insert(t, conn, "prices", map[string]any{"id": id, "link_id": productID, "price_cents": 500, "currency": "usd",
			"recurrence": recurrence, "created_at": testNow, "updated_at": testNow})
	}
	price(1_797_901, "yearly")
	price(1_797_902, nil)
	option := func(id, subscriptionID, priceID int64, deletedAt any) {
		testdb.Insert(t, conn, "payment_options", map[string]any{"id": id, "subscription_id": subscriptionID, "price_id": priceID,
			"deleted_at": deletedAt, "created_at": testNow, "updated_at": testNow})
	}
	subscription := func(id int64, lastOption any) {
		testdb.Insert(t, conn, "subscriptions", map[string]any{"id": id, "link_id": productID, "last_payment_option_id": lastOption,
			"created_at": testNow, "updated_at": testNow})
	}
	subscription(1_797_951, int64(1_797_961))
	option(1_797_961, 1_797_951, 1_797_901, nil)
	// Without a last payment option, the last alive one.
	subscription(1_797_952, nil)
	option(1_797_962, 1_797_952, 1_797_902, nil)
	option(1_797_963, 1_797_952, 1_797_901, testNow)
	subscription(1_797_953, nil)

	usd := func(price int64) *visitorPurchase {
		return &visitorPurchase{totalTransactionCents: sql.NullInt64{Int64: 1_234_599, Valid: true}, priceID: sql.NullInt64{Int64: price, Valid: price != 0},
			currency: sql.NullString{String: "usd", Valid: true}}
	}
	sub := func(id, charges int64) *purchaseSubscription {
		return &purchaseSubscription{id: id, chargeOccurrenceCount: sql.NullInt64{Int64: charges, Valid: charges != 0}}
	}
	for _, c := range []struct {
		name string
		vp   *visitorPurchase
		sub  *purchaseSubscription
		want string
	}{
		{"no price", usd(0), nil, "$12,345.99"},
		{"a yearly price", usd(1_797_901), nil, "$12,345.99 a year"},
		{"a price without a recurrence", usd(1_797_902), nil, "$12,345.99"},
		{"a price that's gone, then the subscription's", usd(9), sub(1_797_951, 0), "$12,345.99 a year"},
		{"the last alive option, charging once", usd(0), sub(1_797_952, 1), "$12,345.99 x 1"},
		{"a recurrence charging once", usd(1_797_901), sub(1_797_952, 1), "$12,345.99 once"},
		{"no total", &visitorPurchase{currency: sql.NullString{String: "usd", Valid: true}}, nil, "$0"},
	} {
		if got, err := h.formattedTotal(p, c.vp, c.sub); err != nil || got != c.want {
			t.Errorf("%s: %q, %v", c.name, got, err)
		}
	}
	// nil.price raises without a payment option.
	if _, err := h.formattedTotal(p, usd(0), sub(1_797_953, 0)); err == nil || !strings.Contains(err.Error(), "subscription payment option") {
		t.Errorf("no payment option: %v", err)
	}
}

// A review reminder's purchase id and email digest show its purchase to a signed-out visitor,
// an expired rental too, among the sales that count reviews; anything else shows none.
func TestAReviewRemindersPurchase(t *testing.T) {
	const purchaseID = int64(1_797_801)
	for _, c := range []struct {
		name    string
		columns map[string]any
		digest  func(e *testEnv) string
		shown   bool
	}{
		{name: "its own digest", shown: true},
		{name: "an expired rental", columns: map[string]any{"rental_expired": true}, shown: true},
		// purchase_props drops purchase_info's bundle_products, so a bundle's renders like any other.
		{name: "a bundle's", columns: map[string]any{"flags": purchaseIsBundle}, shown: true},
		{name: "another digest", digest: func(e *testEnv) string {
			return rails.EmailDigest(e.config.Page.EmailDigestKey, purchaseID, "x@example.com").(string)
		}},
		{name: "a refunded sale", columns: map[string]any{"stripe_refunded": true}},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			conn := testdb.Open(t)
			addPurchase(t, conn, purchaseID, c.columns)
			digest := rails.EmailDigest(e.config.Page.EmailDigestKey, purchaseID, "buyer@example.com").(string)
			if c.digest != nil {
				digest = c.digest(e)
			}
			w := e.get(host, "/l/guide?purchase_id="+e.ids.Encrypt(purchaseID)+"&purchase_email_digest="+url.QueryEscape(digest), nil)
			if w.Code != http.StatusOK || e.railsHit != nil {
				t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
			}
			page := html.UnescapeString(dataPage.FindStringSubmatch(w.Body.String())[1])
			want := `"purchase":null`
			if c.shown {
				want = purchaseHead(e, purchaseID, "buyer@example.com")
			}
			if !strings.Contains(page, want) {
				t.Errorf("want %s\nin %s", want, page)
			}
		})
	}
	// An array id would be looked up as Rails' to_s of it.
	e := newTestEnv(t)
	testdb.Open(t)
	target := "/l/guide?purchase_id[]=x&purchase_email_digest=y"
	if w := e.get(host, target, e.dryRun(host, target, testNow)); w.Header().Get("X-Go-Web-Fallback") != "param purchase_id" {
		t.Errorf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
}

// The review link's purchase wins over the visitor's own, a wrong digest falls through to the
// browser's, another product's purchase is none, and a licensed one goes to Rails as a
// signed-in buyer's would. A verified link skips the custom HTML page for the review form.
func TestAReviewLinksPurchaseAmongOthers(t *testing.T) {
	const linked, other = int64(1_797_821), int64(1_797_822)
	link := func(e *testEnv, id int64, email string) string {
		return "/l/guide?purchase_id=" + e.ids.Encrypt(id) + "&purchase_email_digest=" +
			url.QueryEscape(rails.EmailDigest(e.config.Page.EmailDigestKey, id, email).(string))
	}
	for _, c := range []struct {
		name, want, reason string
		signedIn           bool
		target             func(e *testEnv) string
		setup              func(t *testing.T, e *testEnv, conn *sql.DB)
	}{
		{name: "over the visitor's own", signedIn: true, target: func(e *testEnv) string { return link(e, linked, "buyer@example.com") },
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				addPurchase(t, conn, linked, nil)
				addPurchase(t, conn, other, map[string]any{"purchaser_id": buyerID})
			}, want: "linked"},
		{name: "a wrong digest", target: func(e *testEnv) string { return link(e, linked, "x@example.com") },
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				addPurchase(t, conn, linked, nil)
				addPurchase(t, conn, other, map[string]any{"browser_guid": browserGUID})
			}, want: "other"},
		{name: "another product's purchase", target: func(e *testEnv) string { return link(e, linked, "buyer@example.com") },
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				testdb.Insert(t, conn, "links", map[string]any{"id": int64(1_797_831), "user_id": sellerID, "name": "Else",
					"unique_permalink": "gowebelse", "price_cents": 100, "created_at": testNow, "updated_at": testNow})
				addPurchase(t, conn, linked, map[string]any{"link_id": int64(1_797_831)})
			}, want: "none"},
		{name: "a licensed purchase", reason: "purchase license key", target: func(e *testEnv) string { return link(e, linked, "buyer@example.com") },
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				mustExec(t, conn, "UPDATE links SET flags = flags | ? WHERE id = ?", productIsLicensed, productID)
				addPurchase(t, conn, linked, nil)
				testdb.Insert(t, conn, "licenses", map[string]any{"id": int64(1_797_832), "link_id": productID, "purchase_id": linked,
					"serial": "ABC", "created_at": testNow, "updated_at": testNow})
			}},
		{name: "on a custom HTML page", target: func(e *testEnv) string { return link(e, linked, "buyer@example.com") },
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				customHTML(t, e, conn)
				addPurchase(t, conn, linked, nil)
			}, want: "linked"},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			conn := testdb.Open(t)
			addBuyer(t, conn, nil)
			c.setup(t, e, conn)
			target := c.target(e)
			headers := map[string]string{"Cookie": "_gumroad_guid=" + browserGUID}
			if c.signedIn {
				headers = e.signedIn(buyerID, nil)
			}
			if c.reason != "" {
				maps.Copy(headers, e.dryRun(host, target, testNow))
				if w := e.get(host, target, headers); w.Header().Get("X-Go-Web-Fallback") != c.reason {
					t.Errorf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
				}
				return
			}
			w := e.get(host, target, headers)
			if w.Code != http.StatusOK || e.railsHit != nil {
				t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
			}
			componentProps(t, w.Body.String(), productComponent)
			page := html.UnescapeString(dataPage.FindStringSubmatch(w.Body.String())[1])
			want := map[string]string{"linked": purchaseHead(e, linked, "buyer@example.com"), "other": purchaseHead(e, other, "buyer@example.com"),
				"none": `"purchase":null`}[c.want]
			if !strings.Contains(page, want) {
				t.Errorf("want %s\nin %s", want, page)
			}
		})
	}
}
