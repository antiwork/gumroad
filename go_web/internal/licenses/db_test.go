package licenses

import (
	"context"
	"database/sql"
	"fmt"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/go-sql-driver/mysql"
)

// Golden tests against MySQL: fixture rows in, the exact Rails body out. They need
// GO_WEB_TEST_MYSQL_DSN (a schema-only database); rows use ids 2_000_000-2_999_999.

const (
	fixtureMinID = 2_000_000
	fixtureMaxID = 2_999_999
)

var fixtureTables = []string{
	"users", "links", "licenses", "purchases", "subscriptions", "payment_options", "prices",
	"installment_plan_snapshots", "product_installment_plans", "purchase_custom_fields", "base_variants",
	"base_variants_purchases", "variant_categories", "offer_codes", "purchase_offer_code_discounts",
	"affiliates", "affiliate_credits", "gifts", "imported_customers", "rich_contents",
	"oauth_access_tokens", "team_memberships",
}

func testDB(t *testing.T) *sql.DB {
	t.Helper()
	dsn := os.Getenv("GO_WEB_TEST_MYSQL_DSN")
	if dsn == "" {
		// CI loads the schema and sets the DSN, so a skip there would hide these tests.
		if os.Getenv("CI") != "" {
			t.Fatal("GO_WEB_TEST_MYSQL_DSN is not set")
		}
		t.Skip("GO_WEB_TEST_MYSQL_DSN is not set")
	}
	cfg, err := mysql.ParseDSN(dsn)
	if err != nil {
		t.Fatal(err)
	}
	// As internal/db opens the primary.
	cfg.ParseTime = true
	cfg.InterpolateParams = true
	cfg.Loc = time.UTC
	cfg.Collation = "utf8mb4_unicode_ci"
	cfg.Params = map[string]string{"sql_mode": "'NO_ENGINE_SUBSTITUTION'"}
	db, err := sql.Open("mysql", cfg.FormatDSN())
	if err != nil {
		t.Fatal(err)
	}
	// Columns from migrations a stale schema-only database can lack; db/schema.rb has them.
	for _, column := range [][2]string{{"affiliate_credits", "is_direct_affiliate_credit"}, {"oauth_access_tokens", "team_membership_id"}} {
		var n int
		db.QueryRow("SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?", column[0], column[1]).Scan(&n)
		if n == 0 {
			t.Fatalf("the test database is behind db/schema.rb: %s.%s is missing", column[0], column[1])
		}
	}
	clean := func() {
		for _, table := range fixtureTables {
			if _, err := db.Exec("DELETE FROM "+table+" WHERE id BETWEEN ? AND ?", fixtureMinID, fixtureMaxID); err != nil {
				t.Fatalf("cleaning %s: %v", table, err)
			}
		}
	}
	clean()
	t.Cleanup(func() { clean(); db.Close() })
	return db
}

func mustExec(t *testing.T, db *sql.DB, query string, args ...any) {
	t.Helper()
	if _, err := db.Exec(query, args...); err != nil {
		t.Fatalf("%s: %v", strings.Fields(query)[0:3], err)
	}
}

const stamp = "2026-01-01 00:00:00"

func insertUser(t *testing.T, db *sql.DB, id int64, username, externalID, email any) {
	t.Helper()
	mustExec(t, db, `INSERT INTO users (id, username, external_id, email, recommendation_type, created_at, updated_at)
		VALUES (?, ?, ?, ?, 'own_products', ?, ?)`, id, username, externalID, email, stamp, stamp)
}

func insertLink(t *testing.T, db *sql.DB, id, userID int64, name, unique string, custom any, currency string, flags int64, requireShipping bool) {
	t.Helper()
	mustExec(t, db, `INSERT INTO links (id, user_id, name, unique_permalink, custom_permalink, price_currency_type, flags,
		require_shipping, price_cents, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1000, ?, ?)`,
		id, userID, name, unique, custom, currency, flags, requireShipping, stamp, stamp)
}

func insertLicense(t *testing.T, db *sql.DB, id int64, linkID, purchaseID any, serial string, uses any) {
	t.Helper()
	mustExec(t, db, `INSERT INTO licenses (id, link_id, purchase_id, serial, uses, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		id, linkID, purchaseID, serial, uses, stamp, stamp)
}

// insertPurchase writes a successful purchase; extra sets further columns.
func insertPurchase(t *testing.T, db *sql.DB, id, sellerID, linkID int64, extra map[string]any) {
	t.Helper()
	columns := map[string]any{
		"id": id, "seller_id": sellerID, "link_id": linkID, "created_at": "2026-01-15 10:20:30", "updated_at": stamp,
		"fee_cents": 130, "email": "buyer@example.com", "price_cents": 1000, "displayed_price_cents": 1000,
		"can_contact": true, "referrer": "direct", "card_type": "visa", "card_visual": "**** **** **** 4242",
		"purchase_state": "successful", "flags": 0, "quantity": 1,
	}
	for k, v := range extra {
		columns[k] = v
	}
	var names, marks []string
	var args []any
	for k, v := range columns {
		names = append(names, k)
		marks = append(marks, "?")
		args = append(args, v)
	}
	mustExec(t, db, "INSERT INTO purchases ("+strings.Join(names, ", ")+") VALUES ("+strings.Join(marks, ", ")+")", args...)
}

// expand fills {E:id} with ObfuscateIds.encrypt, {N:id} with encrypt_numeric, and {lt}, {gt},
// {amp} with ActiveSupport's escapes.
func (h *harness) expand(t *testing.T, template string) string {
	t.Helper()
	return expandTemplate(h.ids, template)
}

func expandTemplate(ids idEncoder, template string) string {
	for name, r := range map[string]rune{"{lt}": '<', "{gt}": '>', "{amp}": '&'} {
		template = strings.ReplaceAll(template, name, fmt.Sprintf(`\u%04x`, r))
	}
	return regexp.MustCompile(`\{([EN]):(\d+)\}`).ReplaceAllStringFunc(template, func(m string) string {
		id, _ := strconv.ParseInt(m[3:len(m)-1], 10, 64)
		if m[1] == 'E' {
			return ids.Encrypt(id)
		}
		n, _ := ids.EncryptNumeric(id)
		return strconv.FormatInt(n, 10)
	})
}

func compact(s string) string {
	return regexp.MustCompile(`\n\s*`).ReplaceAllString(strings.TrimSpace(s), "")
}

func licenseUses(t *testing.T, db *sql.DB, id int64) sql.NullInt64 {
	t.Helper()
	var uses sql.NullInt64
	if err := db.QueryRow("SELECT uses FROM licenses WHERE id = ?", id).Scan(&uses); err != nil {
		t.Fatal(err)
	}
	return uses
}

// The rich fixture's purchase object, shared with the database-free assembler test.
const richPurchaseJSON = `{
		"seller_id":"{E:2000001}","product_id":"{E:2000011}","product_name":"Membership","permalink":"member",
		"product_permalink":"https://seller-one.gumroad.com/l/member","short_product_id":"member",
		"email":"Buyer+1@example.com","price":2000,"gumroad_fee":200,"currency":"eur","quantity":2,
		"discover_fee_charged":true,"can_contact":false,"referrer":null,
		"card":{"visual":null,"type":null,"bin":null,"expiry_month":null,"expiry_year":null},
		"order_number":{N:2000201},"sale_id":"{E:2000201}","sale_timestamp":"2026-03-03T03:03:03Z",
		"full_name":"  Jane Doe ","purchaser_id":"2000001001","subscription_id":"{E:2000600}",
		"affiliate_credit_amount_cents":150,"variants":"(Red, Large)",
		"offer_code":{"code":"SAVE5","displayed_amount_off":"€2.50","name":"SAVE5"},
		"test":true,"is_recurring_charge":true,
		"street_address":"1 Main St","country":"United States","state":"CA","zip_code":"94107","city":"",
		"shipping_information":{"full_name":"  Jane Doe ","street_address":"1 Main St","country":"United States","state":"CA","zip_code":"94107","city":""},
		"Company":"Second","Subscribe":true,"email":false,
		"custom_fields":["Company: Acme {lt}Inc{gt}","Subscribe: true","email: false","Company: Second"],
		"license_key":"BBBB1111-BBBB2222-BBBB3333-BBBB4444","is_multiseat_license":true,"ip_country":"United States",
		"shipping_rate":500,"recurrence":"monthly","affiliate":"aff-new@example.com","is_gift_receiver_purchase":false,
		"sku_id":"{E:2000400}","refunded":false,"disputed":true,"dispute_won":true,
		"id":"{E:2000201}","created_at":"2026-03-03T03:03:03Z",
		"subscription_ended_at":null,"subscription_cancelled_at":"2026-02-01T00:00:00Z","subscription_failed_at":null}`

const basicBody = `{"success":true,"uses":1,"purchase":{
	"seller_id":"odHPDs004cxGvLxYm_5Bog==","product_id":"xKVwc7HhUcaBuhnsyxaWSw==",
	"product_name":"Golden {lt}Product{gt} {amp} Co","permalink":"max",
	"product_permalink":"https://seller-one.gumroad.com/l/max","short_product_id":"abcdef",
	"email":"buyer@example.com","price":1000,"gumroad_fee":130,"currency":"usd","quantity":1,
	"discover_fee_charged":false,"can_contact":true,"referrer":"direct",
	"card":{"visual":"**** **** **** 4242","type":"visa","bin":null,"expiry_month":null,"expiry_year":null},
	"order_number":{N:2000200},"sale_id":"TXqrMOOAaNRg598hcA1GWQ==","sale_timestamp":"2026-01-15T10:20:30Z",
	"license_key":"AAAA1111-BBBB2222-CCCC3333-DDDD4444","is_multiseat_license":false,
	"is_gift_receiver_purchase":false,"refunded":false,"disputed":false,"dispute_won":false,
	"id":"TXqrMOOAaNRg598hcA1GWQ==","created_at":"2026-01-15T10:20:30Z","variants":"","custom_fields":[],
	"chargebacked":false}}`

func seedBasic(t *testing.T, db *sql.DB) {
	insertUser(t, db, 2000001, "seller_one", "2000001001", "seller@example.com")
	insertLink(t, db, 2000010, 2000001, "Golden <Product> & Co", "abcdef", "max", "usd", linkIsLicensed, false)
	insertLicense(t, db, 2000100, 2000010, 2000200, "AAAA1111-BBBB2222-CCCC3333-DDDD4444", 0)
	insertPurchase(t, db, 2000200, 2000001, 2000010, nil)
}

func TestGoldenVerifyByProductID(t *testing.T) {
	db := testDB(t)
	h := newHarness(t, db, nil)
	seedBasic(t, db)

	w := h.form(t, "product_id="+h.ids.Encrypt(2000010)+"&license_key=AAAA1111-BBBB2222-CCCC3333-DDDD4444")
	body := h.expand(t, compact(basicBody))
	expectResponse(t, w, http.StatusOK, body)
	expectHeader(t, w, "Content-Type", "application/json; charset=utf-8")
	expectHeader(t, w, "Cache-Control", "max-age=0, private, must-revalidate")
	expectHeader(t, w, "Vary", "Origin")
	if !strings.HasPrefix(w.Header().Get("ETag"), `W/"`) {
		t.Errorf("ETag = %q", w.Header().Get("ETag"))
	}
	if uses := licenseUses(t, db, 2000100); uses.Int64 != 1 {
		t.Fatalf("uses = %v", uses)
	}

	// License#increment! schedules ElasticsearchIndexerWorker.perform_in(2.seconds, ...).
	members, err := h.sidekiq.ZMembers("schedule")
	if err != nil || len(members) != 1 {
		t.Fatalf("schedule = %v, %v", members, err)
	}
	jid := regexp.MustCompile(`"jid":"([0-9a-f]{24})"`).FindStringSubmatch(members[0])
	want := `{"retry":10,"queue":"default","backtrace":true,"class":"ElasticsearchIndexerWorker",` +
		`"args":["update",{"record_id":2000200,"class_name":"Purchase","fields":["license_uses"]}],"jid":"%s","created_at":%d.0}`
	if jid == nil || members[0] != fmt.Sprintf(want, jid[1], testNow.Unix()) {
		t.Fatalf("job = %s", members[0])
	}
	score, _ := h.sidekiq.ZScore("schedule", members[0])
	if want := float64(testNow.Unix()) + 2; score != want {
		t.Fatalf("score = %f, want %f", score, want)
	}
	if strings.Contains(h.logs.String(), "AAAA1111") {
		t.Fatal("the license key must not reach the logs")
	}
}

func TestGoldenVerifyByPermalinkAndTheIncrementSwitch(t *testing.T) {
	db := testDB(t)
	h := newHarness(t, db, nil)
	seedBasic(t, db)
	key := "license_key=AAAA1111-BBBB2222-CCCC3333-DDDD4444"

	// The custom permalink, case-insensitively; legacy id beats link_id beats product_permalink.
	for i, params := range []string{"product_permalink=MAX", "id=abcdef&link_id=nope&product_permalink=nope", "link_id=max&product_permalink=nope"} {
		w := h.form(t, params+"&"+key)
		if body := readBody(t, w); w.Code != 200 || !strings.HasPrefix(body, `{"success":true,"uses":`+strconv.Itoa(i+1)+`,`) {
			t.Fatalf("%s: %d %s", params, w.Code, body)
		}
	}
	w := h.form(t, "id=nope&link_id=abcdef&"+key)
	expectResponse(t, w, http.StatusNotFound, `{"success":false,"message":"That license does not exist for the provided product."}`)

	// Only the string "false" and JSON false skip the increment; the response then has the stored count.
	h.sidekiq.Del("schedule")
	w = h.form(t, "product_permalink=max&increment_uses_count=false&"+key)
	if body := readBody(t, w); !strings.HasPrefix(body, `{"success":true,"uses":3,`) {
		t.Fatalf("got %s", body)
	}
	w = h.do(t, request{contentType: "application/json", body: `{"product_permalink":"max","increment_uses_count":false,"license_key":"AAAA1111-BBBB2222-CCCC3333-DDDD4444"}`})
	if body := readBody(t, w); !strings.HasPrefix(body, `{"success":true,"uses":3,`) {
		t.Fatalf("got %s", body)
	}
	if n, _ := h.sidekiq.ZMembers("schedule"); len(n) != 0 {
		t.Fatal("no increment, no reindex")
	}
	w = h.do(t, request{contentType: "application/json", body: `{"product_permalink":"max","increment_uses_count":0,"license_key":"AAAA1111-BBBB2222-CCCC3333-DDDD4444"}`})
	if body := readBody(t, w); !strings.HasPrefix(body, `{"success":true,"uses":4,`) {
		t.Fatalf("0 is not false: %s", body)
	}
	// serial uses utf8mb4_unicode_ci, so the lookup ignores case as it does for Rails.
	w = h.form(t, "product_permalink=max&increment_uses_count=false&license_key=aaaa1111-bbbb2222-cccc3333-dddd4444")
	if w.Code != 200 {
		t.Fatalf("lowercase key: %d", w.Code)
	}
}

func TestGoldenErrors(t *testing.T) {
	db := testDB(t)
	h := newHarness(t, db, nil)
	seedBasic(t, db)
	key := "&license_key=AAAA1111-BBBB2222-CCCC3333-DDDD4444"
	notFound := `{"success":false,"message":"That license does not exist for the provided product."}`

	expectResponse(t, h.form(t, "product_permalink=max&license_key=nope"), http.StatusNotFound, notFound)
	expectResponse(t, h.form(t, "product_permalink=other"+key), http.StatusNotFound, notFound)
	expectResponse(t, h.form(t, key[1:]), http.StatusNotFound, notFound)
	expectResponse(t, h.form(t, "product_id=not-an-id"+key), http.StatusNotFound, notFound)
	expectResponse(t, h.form(t, "product_id="+h.ids.Encrypt(2000999)+key), http.StatusNotFound, notFound)

	insertLink(t, db, 2000014, 2000001, "Other", "other", nil, "usd", linkIsLicensed, false)
	expectResponse(t, h.form(t, "product_id="+h.ids.Encrypt(2000014)+key), http.StatusNotFound, notFound)

	mustExec(t, db, "UPDATE purchases SET flags = ? WHERE id = 2000200", purchaseIsAccessRevoked)
	expectResponse(t, h.form(t, "product_permalink=max"+key), http.StatusNotFound,
		`{"success":false,"message":"Access to the purchase associated with this license has expired."}`)
	mustExec(t, db, "UPDATE purchases SET flags = 0 WHERE id = 2000200")

	mustExec(t, db, "UPDATE licenses SET disabled_at = ? WHERE id = 2000100", stamp)
	expectResponse(t, h.form(t, "product_permalink=max"+key), http.StatusNotFound, `{"success":false,"message":"This license key has been disabled."}`)
	if uses := licenseUses(t, db, 2000100); uses.Int64 != 0 {
		t.Fatal("a disabled license is not counted")
	}
}

func TestGoldenProductIDEnforcement(t *testing.T) {
	db := testDB(t)
	h := newHarness(t, db, nil)
	seedBasic(t, db)
	params := "product_permalink=abcdef&license_key=AAAA1111-BBBB2222-CCCC3333-DDDD4444"
	required := `{"success":false,"message":"The 'product_id' parameter is required to verify the license for this product. Please set 'product_id' to '{E:2000010}' in the request."}`

	h.redis.Set(forceProductIDTimestampKey, "2025-12-31 00:00:00 UTC")
	expectResponse(t, h.form(t, params), http.StatusInternalServerError, h.expand(t, required))
	// Enforcement runs before the permalink check.
	expectResponse(t, h.form(t, "product_permalink=nomatch&license_key=AAAA1111-BBBB2222-CCCC3333-DDDD4444"), http.StatusInternalServerError, h.expand(t, required))
	if !strings.Contains(h.logs.String(), "responding with HTTP 500 for product: 2000010") {
		t.Fatalf("logs = %s", h.logs.String())
	}

	h.redis.Set(skipProductIDCheckPrefix+"2000010", "true")
	if w := h.form(t, params); w.Code != 200 {
		t.Fatalf("skip flag: %d", w.Code)
	}
	h.redis.Del(skipProductIDCheckPrefix + "2000010")

	h.redis.Set(forceProductIDTimestampKey, "2026-01-02T00:00:00Z")
	if w := h.form(t, params); w.Code != 200 {
		t.Fatalf("product created before the cutoff: %d", w.Code)
	}
	h.redis.Set(forceProductIDTimestampKey, "2025-12-31 00:00:00 UTC")
	if w := h.form(t, "product_id="+h.ids.Encrypt(2000010)+"&license_key=AAAA1111-BBBB2222-CCCC3333-DDDD4444"); w.Code != 200 {
		t.Fatalf("product_id given: %d", w.Code)
	}
}

func TestGoldenRichPurchase(t *testing.T) {
	db := testDB(t)
	h := newHarness(t, db, nil)
	insertUser(t, db, 2000001, "seller_one", "2000001001", "seller@example.com")
	insertUser(t, db, 2000003, nil, "777", "aff@example.com")
	mustExec(t, db, "UPDATE users SET unconfirmed_email = 'aff-new@example.com' WHERE id = 2000003")
	insertLink(t, db, 2000011, 2000001, "Membership", "member", nil, "eur", linkIsRecurringBilling|linkIsLicensed|linkIsPhysical, true)
	mustExec(t, db, "INSERT INTO variant_categories (id, link_id, title) VALUES (2000300, 2000011, 'Size'), (2000301, 2000011, 'Color')")
	// The habtm query has no ORDER BY, so Ruby keeps whatever order MySQL's plan yields; the same
	// SQL here gets the same order. Ids ascend with the join rows so either plan agrees.
	mustExec(t, db, `INSERT INTO base_variants (id, variant_category_id, name, type, flags) VALUES
		(2000400, 2000301, 'Red', 'Variant', 0), (2000401, 2000300, 'Large', 'Variant', 0), (2000402, 2000300, 'Hidden', 'Variant', 1)`)
	mustExec(t, db, "INSERT INTO base_variants_purchases (id, purchase_id, base_variant_id) VALUES (2000500, 2000201, 2000400), (2000501, 2000201, 2000401), (2000502, 2000201, 2000402)")
	insertPurchase(t, db, 2000201, 2000001, 2000011, map[string]any{
		"purchaser_id": 2000001, "subscription_id": 2000600, "offer_code_id": 2000700, "affiliate_id": 2000800,
		"affiliate_credit_cents": 150, "full_name": "  Jane Doe ", "street_address": "1 Main St", "state": "CA",
		"zip_code": "94107", "country": "United States", "ip_country": "United States", "chargeback_date": stamp,
		"flags":          purchaseWasDiscoverFeeCharged | purchaseChargebackReversed | purchaseIsMultiseatLicense,
		"shipping_cents": 500, "quantity": 2, "can_contact": false, "referrer": nil, "email": "Buyer+1@example.com",
		"price_cents": 2000, "fee_cents": 200, "card_type": nil, "card_visual": nil, "created_at": "2026-03-03 03:03:03",
	})
	mustExec(t, db, `INSERT INTO purchase_custom_fields (id, purchase_id, field_type, name, value, created_at, updated_at) VALUES
		(2000900, 2000201, 'text', 'Company', 'Acme <Inc>', ?, ?), (2000901, 2000201, 'checkbox', 'Subscribe', '1', ?, ?),
		(2000902, 2000201, 'terms', 'email', '0', ?, ?), (2000903, 2000201, 'text', 'Company', 'Second', ?, ?)`, stamp, stamp, stamp, stamp, stamp, stamp, stamp, stamp)
	mustExec(t, db, "INSERT INTO subscriptions (id, link_id, cancelled_at, last_payment_option_id, created_at, updated_at) VALUES (2000600, 2000011, '2026-02-01 00:00:00.123456', 2000610, ?, ?)", stamp, stamp)
	mustExec(t, db, "INSERT INTO payment_options (id, subscription_id, price_id) VALUES (2000610, 2000600, 2000620)")
	mustExec(t, db, "INSERT INTO prices (id, link_id, recurrence) VALUES (2000620, 2000011, 'monthly')")
	mustExec(t, db, "INSERT INTO offer_codes (id, user_id, code, amount_cents, currency_type, created_at, updated_at) VALUES (2000700, 2000001, 'SAVE5', 500, 'eur', ?, ?)", stamp, stamp)
	mustExec(t, db, `INSERT INTO purchase_offer_code_discounts (id, purchase_id, offer_code_id, offer_code_amount, offer_code_is_percent,
		pre_discount_minimum_price_cents, created_at, updated_at) VALUES (2000710, 2000201, 2000700, 250, FALSE, 1000, ?, ?)`, stamp, stamp)
	mustExec(t, db, "INSERT INTO affiliates (id, seller_id, affiliate_user_id, type) VALUES (2000800, 2000001, 2000003, 'DirectAffiliate')")
	mustExec(t, db, "INSERT INTO affiliate_credits (id, purchase_id, amount_cents, is_direct_affiliate_credit, created_at, updated_at) VALUES (2000810, 2000201, 150, FALSE, ?, ?)", stamp, stamp)
	// A recurring charge shows its original purchase's license key, not the one being verified.
	insertLicense(t, db, 2000101, 2000011, 2000201, "BBBB0000-BBBB0000-BBBB0000-BBBB0000", 4)
	insertPurchase(t, db, 2000207, 2000001, 2000011, map[string]any{"subscription_id": 2000600, "flags": purchaseIsOriginalSubscriptionPurchase})
	insertLicense(t, db, 2000109, 2000011, 2000207, "BBBB1111-BBBB2222-BBBB3333-BBBB4444", 0)

	w := h.form(t, "product_permalink=member&license_key=BBBB0000-BBBB0000-BBBB0000-BBBB0000")
	expectResponse(t, w, http.StatusOK, h.expand(t, compact(`{"success":true,"uses":5,"purchase":`+richPurchaseJSON+`}`)))

	// A recurring product's purchase without its subscription raises in as_json_for_license.
	mustExec(t, db, "UPDATE purchases SET subscription_id = NULL WHERE id = 2000201")
	if w := h.form(t, "product_permalink=member&license_key=BBBB0000-BBBB0000-BBBB0000-BBBB0000"); w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d", w.Code)
	}
}

func TestGoldenSkuGiftAndNullUses(t *testing.T) {
	db := testDB(t)
	h := newHarness(t, db, nil)
	insertUser(t, db, 2000002, nil, "5550001", "seller2@example.com")
	insertLink(t, db, 2000012, 2000002, "Sku product", "skuprod", "", "jpy", linkIsLicensed|linkSkusEnabled, false)
	mustExec(t, db, "INSERT INTO variant_categories (id, link_id, title) VALUES (2000302, 2000012, 'Edition')")
	mustExec(t, db, "INSERT INTO base_variants (id, link_id, name, type, custom_sku, flags) VALUES (2000403, 2000012, 'Deluxe', 'Sku', 'SKU-1', 0)")
	mustExec(t, db, "INSERT INTO base_variants_purchases (id, purchase_id, base_variant_id) VALUES (2000503, 2000202, 2000403)")
	insertPurchase(t, db, 2000202, 2000002, 2000012, map[string]any{
		"flags": purchaseIsGiftReceiverPurchase, "offer_code_id": 2000701, "stripe_refunded": true,
		"price_cents": 0, "fee_cents": 0, "email": "giftee@example.com", "referrer": nil,
	})
	insertPurchase(t, db, 2000203, 2000002, 2000012, map[string]any{"price_cents": 3000, "email": "gifter@example.com"})
	mustExec(t, db, "INSERT INTO gifts (id, giftee_purchase_id, gifter_purchase_id, link_id, created_at, updated_at) VALUES (2000720, 2000202, 2000203, 2000012, ?, ?)", stamp, stamp)
	mustExec(t, db, "INSERT INTO offer_codes (id, user_id, code, amount_percentage, created_at, updated_at) VALUES (2000701, 2000002, 'TWENTY', 20, ?, ?)", stamp, stamp)
	insertLicense(t, db, 2000102, 2000012, 2000202, "CCCC1111-CCCC2222-CCCC3333-CCCC4444", nil)

	w := h.do(t, request{contentType: "application/json", body: `{"product_id":"` + h.ids.Encrypt(2000012) + `","license_key":"CCCC1111-CCCC2222-CCCC3333-CCCC4444","increment_uses_count":false}`})
	expectResponse(t, w, http.StatusOK, h.expand(t, compact(`{"success":true,"uses":null,"purchase":{
		"seller_id":"{E:2000002}","product_id":"{E:2000012}","product_name":"Sku product","permalink":"skuprod",
		"product_permalink":"https://5550001.gumroad.com/l/skuprod","short_product_id":"skuprod",
		"email":"giftee@example.com","price":0,"gumroad_fee":0,"currency":"jpy","quantity":1,
		"discover_fee_charged":false,"can_contact":true,"referrer":null,
		"card":{"visual":"**** **** **** 4242","type":"visa","bin":null,"expiry_month":null,"expiry_year":null},
		"order_number":{N:2000202},"sale_id":"{E:2000202}","sale_timestamp":"2026-01-15T10:20:30Z",
		"variants":"(Deluxe)","offer_code":{"code":"TWENTY","displayed_amount_off":"20%","name":"TWENTY"},
		"license_key":"CCCC1111-CCCC2222-CCCC3333-CCCC4444","is_multiseat_license":false,
		"is_gift_receiver_purchase":true,"gift_price":3000,"gifter_email":"gifter@example.com",
		"sku_id":"SKU-1","original_sku_id":"{E:2000403}","refunded":true,"disputed":false,"dispute_won":false,
		"id":"{E:2000202}","created_at":"2026-01-15T10:20:30Z","custom_fields":[],"chargebacked":false}}`)))
	if uses := licenseUses(t, db, 2000102); uses.Valid {
		t.Fatal("no increment requested")
	}
	if n, _ := h.sidekiq.ZMembers("schedule"); len(n) != 0 {
		t.Fatal("no increment, no reindex")
	}
	// COALESCE(uses, 0) + 1, and the response echoes the in-memory value.
	w = h.form(t, "product_id="+h.ids.Encrypt(2000012)+"&license_key=CCCC1111-CCCC2222-CCCC3333-CCCC4444")
	if body := readBody(t, w); !strings.HasPrefix(body, `{"success":true,"uses":1,`) || licenseUses(t, db, 2000102).Int64 != 1 {
		t.Fatalf("got %s", body)
	}
}

func TestGoldenVariantContentDecidesTheLicenseKey(t *testing.T) {
	db := testDB(t)
	h := newHarness(t, db, nil)
	insertUser(t, db, 2000001, "seller_one", "2000001001", "seller@example.com")
	insertLink(t, db, 2000013, 2000001, "Tiers", "vcontent", nil, "usd", linkIsLicensed, false)
	mustExec(t, db, "INSERT INTO variant_categories (id, link_id, title) VALUES (2000303, 2000013, 'Tier')")
	mustExec(t, db, "INSERT INTO base_variants (id, variant_category_id, name, type, flags) VALUES (2000404, 2000303, 'Untitled', 'Variant', 0)")
	mustExec(t, db, "INSERT INTO base_variants_purchases (id, purchase_id, base_variant_id) VALUES (2000504, 2000204, 2000404)")
	insertPurchase(t, db, 2000204, 2000001, 2000013, nil)
	insertLicense(t, db, 2000103, 2000013, 2000204, "DDDD1111-DDDD2222-DDDD3333-DDDD4444", 0)
	mustExec(t, db, `INSERT INTO rich_contents (id, entity_id, entity_type, description, created_at, updated_at) VALUES
		(2000950, 2000404, 'BaseVariant', '[{"type":"paragraph","content":[{"type":"text","text":"Hello"}]}]', ?, ?)`, stamp, stamp)
	params := "product_permalink=vcontent&increment_uses_count=false&license_key=DDDD1111-DDDD2222-DDDD3333-DDDD4444"

	body := readBody(t, h.form(t, params))
	if strings.Contains(body, `"license_key"`) || !strings.Contains(body, `"variants":""`) {
		t.Fatalf("variant content without a license key block hides the key: %s", body)
	}
	mustExec(t, db, `UPDATE rich_contents SET description = '[{"type":"bulletList","content":[{"type":"listItem","content":[{"type":"licenseKey"}]}]}]' WHERE id = 2000950`)
	body = readBody(t, h.form(t, params))
	if !strings.Contains(body, `"license_key":"DDDD1111-DDDD2222-DDDD3333-DDDD4444","is_multiseat_license":false`) {
		t.Fatalf("a nested licenseKey block shows the key: %s", body)
	}

	// Sharing one set of pages makes the key product-level, unless that set is blank while a
	// variant's isn't (recoverable_hidden_variant_rich_content?).
	mustExec(t, db, "UPDATE rich_contents SET description = '[]' WHERE id = 2000950")
	mustExec(t, db, "UPDATE links SET flags = ? WHERE id = 2000013", linkIsLicensed|linkHasSameRichContentForVariant)
	if body = readBody(t, h.form(t, params)); !strings.Contains(body, `"license_key"`) {
		t.Fatalf("shared content is product-level: %s", body)
	}
	mustExec(t, db, `INSERT INTO rich_contents (id, entity_id, entity_type, description, created_at, updated_at) VALUES
		(2000951, 2000013, 'Link', '[{"type":"paragraph"}]', ?, ?)`, stamp, stamp)
	mustExec(t, db, `UPDATE rich_contents SET description = '[{"type":"paragraph","content":[{"type":"text","text":"Hello"}]}]' WHERE id = 2000950`)
	if body = readBody(t, h.form(t, params)); strings.Contains(body, `"license_key"`) {
		t.Fatalf("a blank shared page with real variant content falls back to the variant's: %s", body)
	}
	mustExec(t, db, "UPDATE rich_contents SET title = 'Intro' WHERE id = 2000951")
	if body = readBody(t, h.form(t, params)); !strings.Contains(body, `"license_key"`) {
		t.Fatalf("a titled shared page is real content: %s", body)
	}
}

func TestGoldenImportedCustomer(t *testing.T) {
	db := testDB(t)
	h := newHarness(t, db, nil)
	insertUser(t, db, 2000001, "seller_one", "2000001001", "seller@example.com")
	insertLink(t, db, 2000010, 2000001, "Golden <Product> & Co", "abcdef", "max", "usd", linkIsLicensed, false)
	mustExec(t, db, `INSERT INTO imported_customers (id, email, purchase_date, link_id, created_at, updated_at)
		VALUES (2000730, 'imported@example.com', '2024-11-01 12:00:00', 2000010, '2025-01-01 00:00:00', ?)`, stamp)
	mustExec(t, db, "INSERT INTO licenses (id, link_id, imported_customer_id, serial, uses, created_at, updated_at) VALUES (2000104, 2000010, 2000730, 'EEEE1111-EEEE2222-EEEE3333-EEEE4444', 0, ?, ?)", stamp, stamp)

	w := h.form(t, "product_permalink=MAX&license_key=EEEE1111-EEEE2222-EEEE3333-EEEE4444")
	expectResponse(t, w, http.StatusOK, h.expand(t, `{"success":true,"uses":1,"imported_customer":{"email":"imported@example.com","created_at":"2025-01-01T00:00:00Z","timestamp":"about 2 years ago","link_name":"Golden {lt}Product{gt} {amp} Co","product_name":"Golden {lt}Product{gt} {amp} Co","price":null,"is_imported_customer":true,"purchase_email":"imported@example.com","id":"{E:2000730}","can_update":null}}`))
	if n, _ := h.sidekiq.ZMembers("schedule"); len(n) != 0 {
		t.Fatal("License#increment! only reindexes a purchase")
	}
}

func TestGoldenMarksCLIUsersFromTheirToken(t *testing.T) {
	db := testDB(t)
	h := newHarness(t, db, nil)
	seedBasic(t, db)
	mustExec(t, db, "INSERT INTO oauth_access_tokens (id, resource_owner_id, application_id, token, created_at) VALUES (2000740, 2000001, 1, 'golden-token', ?), (2000741, 2000001, 1, 'mcp-token', ?)", stamp, stamp)
	mustExec(t, db, "UPDATE oauth_access_tokens SET resource = 'https://gumroad.com/claude/v1/mcp' WHERE id = 2000741")
	userFlags := func() int64 {
		var flags int64
		db.QueryRow("SELECT flags FROM users WHERE id = 2000001").Scan(&flags)
		return flags
	}
	params := "product_permalink=max&license_key=AAAA1111-BBBB2222-CCCC3333-DDDD4444"
	verify := func(headers map[string]string) {
		t.Helper()
		if w := h.do(t, request{contentType: "application/x-www-form-urlencoded", body: params, headers: headers}); w.Code != 200 {
			t.Fatalf("status %d", w.Code)
		}
	}

	verify(map[string]string{"Authorization": "Bearer golden-token", "User-Agent": "curl/8"})
	if userFlags()&userHasUsedCLI != 0 {
		t.Fatal("only gumroad-cli marks the user")
	}
	verify(map[string]string{"Authorization": "Bearer mcp-token", "User-Agent": "gumroad-cli/1.4.0"})
	if userFlags()&userHasUsedCLI != 0 {
		t.Fatal("an MCP-bound token is no token here")
	}
	verify(map[string]string{"Authorization": "Bearer golden-token", "User-Agent": "Gumroad-CLI/1.4.0"})
	if flags := userFlags(); flags&userHasUsedCLI == 0 || flags&1 == 0 {
		t.Fatalf("flags = %b", flags)
	}
	if !strings.Contains(h.logs.String(), "api v2 user:2000001 token:2000740 in api/v2/licenses#verify") {
		t.Fatalf("logs = %s", h.logs.String())
	}
	// The access_token param works too, and a before_action halt skips the after_action.
	mustExec(t, db, "UPDATE users SET flags = 1 WHERE id = 2000001")
	h.do(t, request{contentType: "application/x-www-form-urlencoded", body: "access_token=golden-token&product_permalink=max&license_key=nope", headers: map[string]string{"User-Agent": "gumroad-cli/1"}})
	if userFlags()&userHasUsedCLI != 0 {
		t.Fatal("a 404 from fetch_valid_license halts before log_method_use")
	}
	h.do(t, request{contentType: "application/x-www-form-urlencoded", body: "access_token=golden-token&" + params, headers: map[string]string{"User-Agent": "gumroad-cli/1"}})
	if userFlags()&userHasUsedCLI == 0 {
		t.Fatal("access_token param")
	}
}

func TestGoldenTokenWithoutItsOwnerIsANotFound(t *testing.T) {
	db := testDB(t)
	h := newHarness(t, db, nil)
	seedBasic(t, db)
	mustExec(t, db, `INSERT INTO oauth_access_tokens (id, resource_owner_id, application_id, token, created_at)
		VALUES (2000742, NULL, 1, 'app-token', ?), (2000743, 2000998, 1, 'orphan-token', ?)`, stamp, stamp)
	for _, token := range []string{"app-token", "orphan-token"} {
		// current_api_user's User.find raises before clean_params, so nothing is counted.
		w := h.do(t, request{contentType: "application/x-www-form-urlencoded", body: "product_permalink=max&license_key=AAAA1111-BBBB2222-CCCC3333-DDDD4444",
			headers: map[string]string{"Authorization": "Bearer " + token}})
		if body := readBody(t, w); w.Code != http.StatusNotFound || !strings.Contains(body, "Page not found") {
			t.Fatalf("%s: %d %.80q", token, w.Code, body)
		}
		w = h.do(t, request{target: "/v2/licenses/verify.json", contentType: "application/x-www-form-urlencoded", body: "license_key[x]=1",
			headers: map[string]string{"Authorization": "Bearer " + token}})
		expectResponse(t, w, http.StatusNotFound, `{"status":404,"error":"Not Found"}`)
	}
	if uses := licenseUses(t, db, 2000100); uses.Int64 != 0 {
		t.Fatalf("uses = %v", uses)
	}
	// An unknown token is simply no token.
	if w := h.do(t, request{contentType: "application/x-www-form-urlencoded", body: "product_permalink=max&license_key=AAAA1111-BBBB2222-CCCC3333-DDDD4444",
		headers: map[string]string{"Authorization": "Bearer nope"}}); w.Code != 200 {
		t.Fatalf("unknown token: %d", w.Code)
	}
}

func TestStoreQueriesRunAgainstTheSchema(t *testing.T) {
	db := testDB(t)
	s := &store{db: db}
	ctx := context.Background()
	insertUser(t, db, 2000001, "seller_one", "2000001001", "seller@example.com")
	insertLink(t, db, 2000015, 2000001, "Installments", "inst", nil, "usd", linkIsRecurringBilling, false)
	mustExec(t, db, "INSERT INTO subscriptions (id, link_id, flags, last_payment_option_id, created_at, updated_at) VALUES (2000601, 2000015, ?, 2000611, ?, ?)", subscriptionIsInstallmentPlan, stamp, stamp)
	mustExec(t, db, "INSERT INTO payment_options (id, subscription_id, product_installment_plan_id) VALUES (2000611, 2000601, 2000630)")
	mustExec(t, db, "INSERT INTO product_installment_plans (id, link_id, number_of_installments, recurrence, created_at, updated_at) VALUES (2000630, 2000015, 3, 'quarterly', ?, ?)", stamp, stamp)

	sub, err := s.subscription(ctx, 2000601)
	if err != nil || sub.recurrenceErr != nil || sub.recurrence.String != "quarterly" {
		t.Fatalf("installment plan: %+v %v", sub, err)
	}
	mustExec(t, db, "INSERT INTO installment_plan_snapshots (id, payment_option_id, number_of_installments, recurrence, total_price_cents, created_at, updated_at) VALUES (2000631, 2000611, 3, 'monthly', 900, ?, ?)", stamp, stamp)
	if sub, _ = s.subscription(ctx, 2000601); sub.recurrence.String != "monthly" {
		t.Fatalf("snapshot wins: %+v", sub)
	}
	mustExec(t, db, "UPDATE subscriptions SET flags = 0, last_payment_option_id = NULL WHERE id = 2000601")
	if sub, _ = s.subscription(ctx, 2000601); sub.recurrenceErr == nil {
		t.Fatal("a payment option without a price raises")
	}
	// A license with a NULL serial still can't be found by a blank key: Rails validates presence.
	mustExec(t, db, "INSERT INTO licenses (id, link_id, serial, created_at, updated_at) VALUES (2000105, 2000015, 'FFFF', ?, ?)", stamp, stamp)
	if lk, err := s.findLicense(ctx, nil, nil); lk != nil || err != nil {
		t.Fatalf("blank key: %v %v", lk, err)
	}
	productID := int64(2000999)
	if lk, err := s.findLicense(ctx, &productID, "FFFF"); lk != nil || err != nil {
		t.Fatal("product.licenses scopes to the product")
	}
	mustExec(t, db, "UPDATE licenses SET link_id = 2000999 WHERE id = 2000105")
	if lk, err := s.findLicense(ctx, &productID, "FFFF"); lk != nil || err != nil {
		t.Fatal("a license whose product row is gone isn't reachable through product.licenses")
	}
	if lk, err := s.findLicense(ctx, nil, "ffff"); err != nil || lk == nil || lk.product != nil || lk.purchase != nil {
		t.Fatalf("License.find_by(serial:) still finds it, with no link: %+v %v", lk, err)
	}
}

// statements counts what the request sends MySQL, on a single pooled connection.
func statements(t *testing.T, db *sql.DB, run func()) int {
	t.Helper()
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { db.SetMaxOpenConns(0) })
	questions := func() int {
		var name string
		var n int
		if err := db.QueryRow("SHOW SESSION STATUS LIKE 'Questions'").Scan(&name, &n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	before := questions()
	run()
	// The second SHOW counts itself.
	return questions() - before - 1
}

func TestATypicalVerifyRunsFiveStatements(t *testing.T) {
	db := testDB(t)
	h := newHarness(t, db, nil)
	seedBasic(t, db)
	h.form(t, "product_permalink=max&license_key=AAAA1111-BBBB2222-CCCC3333-DDDD4444")
	n := statements(t, db, func() {
		if w := h.form(t, "product_permalink=max&license_key=AAAA1111-BBBB2222-CCCC3333-DDDD4444"); w.Code != 200 {
			t.Fatalf("status %d", w.Code)
		}
	})
	// The license lookup, the uses UPDATE, users, variant_attributes, purchase_custom_fields.
	if n != 5 {
		t.Fatalf("%d statements", n)
	}
}

func TestTheTokenPathAddsOneStatement(t *testing.T) {
	db := testDB(t)
	h := newHarness(t, db, nil)
	seedBasic(t, db)
	mustExec(t, db, "INSERT INTO oauth_access_tokens (id, resource_owner_id, application_id, token, created_at) VALUES (2000744, 2000001, 1, 'count-token', ?)", stamp)
	verify := func() {
		w := h.do(t, request{contentType: "application/x-www-form-urlencoded", body: "product_permalink=max&license_key=AAAA1111-BBBB2222-CCCC3333-DDDD4444",
			headers: map[string]string{"Authorization": "Bearer count-token", "User-Agent": "gumroad-cli/1.0"}})
		if w.Code != 200 {
			t.Fatalf("status %d", w.Code)
		}
	}
	// The token and its owner in one statement, then the five of a typical verify; the CLI
	// flag's UPDATE only runs until the owner has it.
	if n := statements(t, db, verify); n != 7 {
		t.Fatalf("first CLI use: %d statements", n)
	}
	if n := statements(t, db, verify); n != 6 {
		t.Fatalf("later uses: %d statements", n)
	}
}

func TestGoldenLicenseKeyIsTheVerifiedLicensesOwn(t *testing.T) {
	db := testDB(t)
	h := newHarness(t, db, nil)
	seedBasic(t, db)
	// A second license on the same purchase: has_one :license's inverse makes it the key shown.
	insertLicense(t, db, 2000106, 2000010, 2000200, "ZZZZ1111-ZZZZ2222-ZZZZ3333-ZZZZ4444", 0)
	body := readBody(t, h.form(t, "product_permalink=max&increment_uses_count=false&license_key=ZZZZ1111-ZZZZ2222-ZZZZ3333-ZZZZ4444"))
	if !strings.Contains(body, `"license_key":"ZZZZ1111-ZZZZ2222-ZZZZ3333-ZZZZ4444"`) {
		t.Fatalf("got %s", body)
	}
}

func TestGoldenRecurringChargeShowsTheOriginalPurchasesKey(t *testing.T) {
	db := testDB(t)
	h := newHarness(t, db, nil)
	insertUser(t, db, 2000001, "seller_one", "2000001001", "seller@example.com")
	insertLink(t, db, 2000016, 2000001, "Monthly", "monthly", nil, "usd", linkIsRecurringBilling|linkIsLicensed, false)
	mustExec(t, db, "INSERT INTO subscriptions (id, link_id, last_payment_option_id, created_at, updated_at) VALUES (2000602, 2000016, 2000612, ?, ?)", stamp, stamp)
	mustExec(t, db, "INSERT INTO payment_options (id, subscription_id, price_id) VALUES (2000612, 2000602, 2000622)")
	mustExec(t, db, "INSERT INTO prices (id, link_id, recurrence) VALUES (2000622, 2000016, 'yearly')")
	insertPurchase(t, db, 2000205, 2000001, 2000016, map[string]any{"subscription_id": 2000602, "flags": purchaseIsOriginalSubscriptionPurchase})
	insertPurchase(t, db, 2000206, 2000001, 2000016, map[string]any{"subscription_id": 2000602})
	mustExec(t, db, `INSERT INTO purchase_custom_fields (id, purchase_id, field_type, name, value, created_at, updated_at)
		VALUES (2000904, 2000205, 'text', 'Team', 'Blue', ?, ?)`, stamp, stamp)
	insertLicense(t, db, 2000107, 2000016, 2000205, "ORIG1111-ORIG2222-ORIG3333-ORIG4444", 0)
	insertLicense(t, db, 2000108, 2000016, 2000206, "CHRG1111-CHRG2222-CHRG3333-CHRG4444", 0)

	body := readBody(t, h.form(t, "product_permalink=monthly&increment_uses_count=false&license_key=CHRG1111-CHRG2222-CHRG3333-CHRG4444"))
	// Purchase#license for a recurring charge is subscription.original_purchase.license, and the
	// charge's empty custom fields fall back to the original purchase's.
	for _, want := range []string{`"is_recurring_charge":true`, `"custom_fields":[]`, `"license_key":"ORIG1111-ORIG2222-ORIG3333-ORIG4444"`, `"recurrence":"yearly"`} {
		if !strings.Contains(body, want) {
			t.Errorf("missing %s in %s", want, body)
		}
	}
	if strings.Index(body, `"custom_fields":[]`) > strings.Index(body, `"license_key"`) {
		t.Errorf("the subscription's custom fields put custom_fields in the payload, before license_key: %s", body)
	}
	body = readBody(t, h.form(t, "product_permalink=monthly&increment_uses_count=false&license_key=ORIG1111-ORIG2222-ORIG3333-ORIG4444"))
	if !strings.Contains(body, `"Team":"Blue","custom_fields":["Team: Blue"],"license_key":"ORIG1111-ORIG2222-ORIG3333-ORIG4444"`) {
		t.Errorf("original purchase: %s", body)
	}
}

func insertToken(t *testing.T, db *sql.DB, id int64, ownerID any, token string, extra string) {
	t.Helper()
	mustExec(t, db, "INSERT INTO oauth_access_tokens (id, resource_owner_id, application_id, token, created_at) VALUES (?, ?, 1, ?, ?)", id, ownerID, token, stamp)
	if extra != "" {
		mustExec(t, db, "UPDATE oauth_access_tokens SET "+extra+" WHERE id = ?", id)
	}
}

func cliFlag(t *testing.T, db *sql.DB, userID int64) bool {
	t.Helper()
	var flags int64
	if err := db.QueryRow("SELECT flags FROM users WHERE id = ?", userID).Scan(&flags); err != nil {
		t.Fatal(err)
	}
	return flags&userHasUsedCLI != 0
}

func cliRequest(token, body string) request {
	return request{contentType: "application/x-www-form-urlencoded", body: body,
		headers: map[string]string{"Authorization": "Bearer " + token, "User-Agent": "gumroad-cli/1.0"}}
}

const basicParams = "product_permalink=max&license_key=AAAA1111-BBBB2222-CCCC3333-DDDD4444"

// doorkeeper_token never checks validity, so log_method_use runs for revoked and expired
// tokens too, and for the disabled-license 404 the action itself renders.
func TestGoldenAfterActionRunsForAnyFoundToken(t *testing.T) {
	db := testDB(t)
	h := newHarness(t, db, nil)
	seedBasic(t, db)
	insertToken(t, db, 2000750, 2000001, "revoked-token", "revoked_at = '2026-01-02 00:00:00'")
	insertToken(t, db, 2000751, 2000001, "expired-token", "expires_in = 60")

	for _, token := range []string{"revoked-token", "expired-token"} {
		mustExec(t, db, "UPDATE users SET flags = 1 WHERE id = 2000001")
		if w := h.do(t, cliRequest(token, basicParams)); w.Code != 200 {
			t.Fatalf("%s: %d", token, w.Code)
		}
		if !cliFlag(t, db, 2000001) {
			t.Errorf("%s did not mark the CLI user", token)
		}
	}
	if !strings.Contains(h.logs.String(), "api v2 user:2000001 token:2000751 in api/v2/licenses#verify") {
		t.Fatalf("logs = %s", h.logs.String())
	}

	mustExec(t, db, "UPDATE users SET flags = 1 WHERE id = 2000001")
	mustExec(t, db, "UPDATE licenses SET disabled_at = ? WHERE id = 2000100", stamp)
	h.logs.Reset()
	expectResponse(t, h.do(t, cliRequest("revoked-token", basicParams)), http.StatusNotFound, `{"success":false,"message":"This license key has been disabled."}`)
	if !cliFlag(t, db, 2000001) || !strings.Contains(h.logs.String(), "api v2 user:2000001 token:2000750") {
		t.Fatalf("a disabled license still runs the after_action: %s", h.logs.String())
	}
}

func TestGoldenFilterHaltsSkipTheAfterAction(t *testing.T) {
	db := testDB(t)
	h := newHarness(t, db, nil)
	seedBasic(t, db)
	insertToken(t, db, 2000752, 2000001, "halt-token", "")
	h.redis.Set(forceProductIDTimestampKey, "2025-12-31 00:00:00 UTC")

	w := h.do(t, cliRequest("halt-token", "product_permalink=abcdef&license_key=AAAA1111-BBBB2222-CCCC3333-DDDD4444"))
	if w.Code != http.StatusInternalServerError || strings.Contains(h.logs.String(), "api v2 user:") || cliFlag(t, db, 2000001) {
		t.Fatalf("the product_id 500 renders in a before_action: %d %s", w.Code, h.logs.String())
	}
	// A rendered error carries render json:'s headers and Rack::ETag's no-cache, never an ETag.
	expectHeader(t, w, "Content-Type", "application/json; charset=utf-8")
	expectHeader(t, w, "Cache-Control", "no-cache")
	expectHeader(t, w, "ETag", "")
	expectHeader(t, w, "Vary", "Origin")
	expectHeader(t, w, "X-Revision", "rev")

	w = h.do(t, cliRequest("halt-token", "product_permalink=max&license_key=nope"))
	if w.Code != http.StatusNotFound || cliFlag(t, db, 2000001) {
		t.Fatalf("fetch_valid_license's 404 halts too: %d", w.Code)
	}
	expectHeader(t, w, "Content-Type", "application/json; charset=utf-8")
	expectHeader(t, w, "Cache-Control", "no-cache")
	expectHeader(t, w, "ETag", "")
}

func TestGoldenBrandTokenLogsItsOwner(t *testing.T) {
	db := testDB(t)
	h := newHarness(t, db, nil)
	seedBasic(t, db)
	insertUser(t, db, 2000002, "member_one", "2000002002", "member@example.com")
	mustExec(t, db, `INSERT INTO team_memberships (id, seller_id, user_id, role, created_at, updated_at)
		VALUES (2000760, 2000001, 2000002, 'admin', ?, ?)`, stamp, stamp)
	insertToken(t, db, 2000753, 2000001, "brand-token", "team_membership_id = 2000760, created_at = '2026-06-01 00:00:00'")

	if w := h.do(t, cliRequest("brand-token", basicParams)); w.Code != 200 {
		t.Fatalf("status %d", w.Code)
	}
	// current_resource_owner is the token's resource owner, not the team member it acts as.
	if !strings.Contains(h.logs.String(), "api v2 user:2000001 token:2000753") || !cliFlag(t, db, 2000001) || cliFlag(t, db, 2000002) {
		t.Fatalf("logs = %s", h.logs.String())
	}
}

func TestGoldenReindexFailureStillCountsTheUse(t *testing.T) {
	db := testDB(t)
	h := newHarness(t, db, nil)
	seedBasic(t, db)
	h.sidekiq.SetError("LOADING Redis is loading the dataset in memory")

	w := h.form(t, basicParams)
	if body := readBody(t, w); w.Code != 200 || !strings.HasPrefix(body, `{"success":true,"uses":1,`) {
		t.Fatalf("%d %s", w.Code, body)
	}
	if uses := licenseUses(t, db, 2000100); uses.Int64 != 1 {
		t.Fatalf("uses = %v", uses)
	}
	if !strings.Contains(h.logs.String(), "Could not schedule the license_uses reindex") {
		t.Fatalf("logs = %s", h.logs.String())
	}
}

// Rails reads a Bearer header in current_api_user before any filter reads params, so an
// owner-less token wins over a body JSON can't parse. A token in the params can't be seen.
func TestGoldenOwnerlessTokenBeatsAJSONParseError(t *testing.T) {
	db := testDB(t)
	h := newHarness(t, db, nil)
	seedBasic(t, db)
	insertToken(t, db, 2000754, nil, "ownerless-token", "")
	insertToken(t, db, 2000755, 2000001, "owned-token", "")
	broken := `{"license_key":`

	w := h.do(t, request{contentType: "application/json", body: broken, headers: map[string]string{"Authorization": "Bearer ownerless-token", "Accept": "application/json"}})
	expectResponse(t, w, http.StatusNotFound, `{"status":404,"error":"Not Found"}`)
	// ShowExceptions answers with its own headers, so the controller's debug headers are gone.
	expectHeader(t, w, "X-Revision", "")
	expectHeader(t, w, "X-GR", "")
	expectHeader(t, w, "Cache-Control", "")

	w = h.do(t, request{contentType: "application/json", body: broken, headers: map[string]string{"Authorization": "Bearer ownerless-token"}})
	if body := readBody(t, w); w.Code != http.StatusNotFound || !strings.Contains(body, "Page not found") {
		t.Fatalf("html: %d %.60q", w.Code, body)
	}
	for _, headers := range []map[string]string{
		{"Authorization": "Bearer owned-token", "Accept": "application/json"},
		{"Authorization": "Bearer nope", "Accept": "application/json"},
		{"Accept": "application/json"},
	} {
		w = h.do(t, request{contentType: "application/json", body: broken, headers: headers})
		expectResponse(t, w, http.StatusBadRequest, `{"status":400,"error":"Bad Request"}`)
	}
	w = h.do(t, request{target: "/v2/licenses/verify?access_token=ownerless-token", contentType: "application/json", body: broken, headers: map[string]string{"Accept": "application/json"}})
	expectResponse(t, w, http.StatusBadRequest, `{"status":400,"error":"Bad Request"}`)
	if uses := licenseUses(t, db, 2000100); uses.Int64 != 0 {
		t.Fatal("nothing was verified")
	}
}
