package licenses

import (
	"database/sql"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/obfuscate"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

func productionConfig(t *testing.T) *config {
	t.Helper()
	getenv := func(name string) string {
		return map[string]string{"RAILS_ENV": "production", "REVISION": "rev"}[name]
	}
	env, err := web.LoadEnvironment(getenv)
	if err != nil {
		t.Fatal(err)
	}
	return newConfig(env)
}

func testIDs(t *testing.T) *obfuscate.IDs {
	t.Helper()
	ids, err := obfuscate.New("test", "1234")
	if err != nil {
		t.Fatal(err)
	}
	return ids
}

func ns(s string) sql.NullString { return sql.NullString{String: s, Valid: true} }
func ni(n int64) sql.NullInt64   { return sql.NullInt64{Int64: n, Valid: true} }
func nb(b bool) sql.NullBool     { return sql.NullBool{Bool: b, Valid: true} }
func nt(s string) db.NullTime {
	t, err := time.Parse("2006-01-02 15:04:05", s)
	if err != nil {
		panic(err)
	}
	return db.NullTime{Time: t, Valid: true}
}

// richGraph is TestGoldenRichPurchase's fixture as loadPurchaseGraph reads it.
func richGraph() *purchaseGraph {
	seller := &user{id: 2000001, username: ns("seller_one"), externalID: ns("2000001001"), email: ns("seller@example.com"), flags: 1}
	return &purchaseGraph{
		purchase: &purchase{
			id: 2000201, sellerID: ni(2000001), linkID: ni(2000011), createdAt: nt("2026-03-03 03:03:03"), feeCents: ni(200),
			email: ns("Buyer+1@example.com"), priceCents: ni(2000), streetAddress: ns("1 Main St"), state: ns("CA"), zipCode: ns("94107"),
			country: ns("United States"), fullName: ns("  Jane Doe "), purchaserID: ni(2000001), canContact: nb(false),
			chargebackDate: nt("2026-01-01 00:00:00"), ipCountry: ns("United States"),
			flags:       purchaseWasDiscoverFeeCharged | purchaseChargebackReversed | purchaseIsMultiseatLicense,
			offerCodeID: ni(2000700), subscriptionID: ni(2000600), affiliateCreditCents: ni(150), quantity: 2,
			shippingCents: ni(500), affiliateID: ni(2000800),
		},
		seller: seller,
		product: &product{id: 2000011, userID: ni(2000001), name: "Membership", uniquePermalink: ns("member"), priceCurrencyType: ns("eur"),
			requireShipping: nb(true), flags: linkIsRecurringBilling | linkIsLicensed | linkIsPhysical},
		productUser: seller,
		purchaser:   seller,
		subscription: &subscription{id: 2000600, cancelledAt: db.NullTime{Time: time.Date(2026, 2, 1, 0, 0, 0, 123456000, time.UTC), Valid: true},
			recurrence: ns("monthly")},
		customFields: []customField{
			{"Company", "text", ns("Acme <Inc>")}, {"Subscribe", "checkbox", ns("1")}, {"email", "terms", ns("0")}, {"Company", "text", ns("Second")},
		},
		hasAffiliateCredit: true,
		affiliate:          &affiliate{id: 2000800, typ: "DirectAffiliate"},
		affiliateUser:      &user{id: 2000003, externalID: ns("777"), email: ns("aff@example.com"), unconfirmedEmail: ns("aff-new@example.com")},
		variants: []*baseVariant{
			{id: 2000400, typ: ns("Variant"), name: ns("Red")},
			{id: 2000401, typ: ns("Variant"), name: ns("Large")},
			{id: 2000402, typ: ns("Variant"), name: ns("Hidden"), flags: baseVariantIsDefaultSku},
		},
		offerCode:           &offerCode{code: ns("SAVE5"), amountCents: ni(500), discountAmount: ni(250), discountIsPercent: nb(false)},
		licenseKeyPermitted: true,
		licenseSerial:       ns("BBBB1111-BBBB2222-BBBB3333-BBBB4444"),
	}
}

func TestBuildPurchaseJSONFollowsPayloadThenAsJSONOrder(t *testing.T) {
	ids := testIDs(t)
	got, err := buildPurchaseJSON(richGraph(), productionConfig(t), ids)
	if err != nil {
		t.Fatal(err)
	}
	if want := expandTemplate(ids, compact(richPurchaseJSON)); rails.EncodeJSON(got) != want {
		t.Fatalf("got\n%s\nwant\n%s", rails.EncodeJSON(got), want)
	}
}

func TestBuildPurchaseJSONRaisesWhereRubyWould(t *testing.T) {
	cfg, ids := productionConfig(t), testIDs(t)
	for name, mutate := range map[string]func(*purchaseGraph){
		"no seller":                      func(g *purchaseGraph) { g.seller = nil },
		"no product user":                func(g *purchaseGraph) { g.productUser = nil },
		"recurring without subscription": func(g *purchaseGraph) { g.subscription = nil },
		"subscription without price":     func(g *purchaseGraph) { g.subscription.recurrenceErr = errMissingRecord },
		"affiliate without user":         func(g *purchaseGraph) { g.affiliateUser = nil },
		"unknown currency":               func(g *purchaseGraph) { g.product.priceCurrencyType = ns("xyz") },
		"gift receiver without gift": func(g *purchaseGraph) {
			g.purchase.flags |= purchaseIsGiftReceiverPurchase
		},
		"past encrypt_numeric": func(g *purchaseGraph) { g.purchase.id = 1 << 30 },
	} {
		g := richGraph()
		mutate(g)
		if _, err := buildPurchaseJSON(g, cfg, ids); err == nil {
			t.Errorf("%s: want an error", name)
		}
	}
	if !errors.Is(errMissingRecord, errMissingRecord) {
		t.Fatal("sentinel")
	}
}

func TestPurchaseKeysThatDependOnTheProduct(t *testing.T) {
	cfg, ids := productionConfig(t), testIDs(t)
	g := richGraph()
	g.product.flags = linkIsLicensed | linkSkusEnabled
	g.product.requireShipping = nb(false)
	g.product.customPermalink = ns("custom")
	g.product.priceCurrencyType = sql.NullString{}
	g.subscription, g.subscriptionCustomFields, g.customFields = nil, nil, nil
	g.variants = []*baseVariant{{id: 2000403, typ: ns("Sku"), name: ns("Deluxe")}}
	g.offerCode.discountAmount, g.offerCode.discountIsPercent = ni(15), nb(true)
	g.purchase.stripeRefunded = nb(true)
	g.productUser = &user{id: 9, externalID: ns("12345")}
	got, err := buildPurchaseJSON(g, cfg, ids)
	if err != nil {
		t.Fatal(err)
	}
	body := rails.EncodeJSON(got)
	for _, want := range []string{
		`"permalink":"custom","product_permalink":"https://12345.gumroad.com/l/custom"`,
		`"currency":null`,
		`"offer_code":{"code":"SAVE5","displayed_amount_off":"15%","name":"SAVE5"}`,
		`"sku_id":"` + ids.Encrypt(2000403) + `","refunded":true`,
		`"id":"` + ids.Encrypt(2000201) + `","created_at":"2026-03-03T03:03:03Z","custom_fields":[],"chargebacked":false}`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("missing %s in\n%s", want, body)
		}
	}
	for _, absent := range []string{`"shipping_information"`, `"recurrence"`, `"shipping_rate"`, `"original_sku_id"`, `"subscription_ended_at"`} {
		if strings.Contains(body, absent) {
			t.Errorf("unexpected %s in\n%s", absent, body)
		}
	}
}
