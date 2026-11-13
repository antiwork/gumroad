package downloads

import (
	"net/http"
	"testing"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
)

// purchaseHash renders token's page and returns its purchase prop.
func (e *testEnv) purchaseHash(token string) *rails.Hash {
	e.t.Helper()
	w := e.page(token, nil)
	if w.Code != http.StatusOK || e.railsHit != nil {
		e.t.Fatalf("status %d, rails %v: %s", w.Code, e.railsHit != nil, w.Header().Get("X-Go-Web-Fallback"))
	}
	return pageProps(e.t, w.Body.String()).Value("purchase").(*rails.Hash)
}

func TestTheReviewFormShowsThePurchasesReview(t *testing.T) {
	e := newPageEnv(t)
	token := e.purchase(productID, map[string]any{"price_cents": 500}, nil)
	if got := e.purchaseHash(token).Value("review"); got != nil {
		t.Errorf("review without one: %s", rails.EncodeJSON(got))
	}
	review := int64(1_780_901)
	testdb.Insert(t, e.db, "product_reviews", map[string]any{"id": review, "purchase_id": nextPurchase, "link_id": productID, "rating": 4,
		"created_at": testNow, "updated_at": testNow})
	if got := rails.EncodeJSON(e.purchaseHash(token).Value("review")); got != `{"anonymous":false,"rating":4,"message":null,"video":null}` {
		t.Errorf("review %s", got)
	}
	e.db.Exec("UPDATE product_reviews SET anonymous = TRUE, message = 'Great' WHERE id = ?", review)
	if got := rails.EncodeJSON(e.purchaseHash(token).Value("review")); got != `{"anonymous":true,"rating":4,"message":"Great","video":null}` {
		t.Errorf("anonymous review %s", got)
	}

	// An editable video's thumbnail is an Active Storage variant, which Rails renders.
	testdb.Insert(t, e.db, "product_review_videos", map[string]any{"id": int64(1_780_911), "product_review_id": review,
		"approval_status": "approved", "created_at": testNow, "updated_at": testNow})
	if e.page(token, nil); e.railsHit == nil {
		t.Error("a review with an editable video was rendered")
	}
	e.db.Exec("UPDATE product_review_videos SET approval_status = 'rejected' WHERE id = ?", int64(1_780_911))
	if got := e.purchaseHash(token).Value("review"); got == nil {
		t.Error("a rejected video hid the review")
	}
}

func TestPostPurchaseCustomFieldsRenderTheirValuesAndFiles(t *testing.T) {
	e := newPageEnv(t)
	token := e.purchase(productID, map[string]any{"price_cents": 500}, nil)
	id := nextPurchase
	field := func(rowID int64, fieldType, value any, flags, customFieldID any) {
		testdb.Insert(t, e.db, "purchase_custom_fields", map[string]any{"id": rowID, "purchase_id": id, "field_type": fieldType,
			"name": "Field", "value": value, "flags": flags, "custom_field_id": customFieldID, "created_at": testNow, "updated_at": testNow})
	}
	// Checkout fields, and a field without a custom field, aren't shown.
	field(1_780_921, "text", "At checkout", 0, int64(1_780_931))
	field(1_780_922, "text", "Orphan", 1, nil)
	if got := rails.EncodeJSON(e.purchaseHash(token).Value("purchase_custom_fields")); got != `[]` {
		t.Errorf("checkout fields %s", got)
	}

	field(1_780_923, "long_text", nil, 1, int64(1_780_932))
	field(1_780_924, "checkbox", "1", 1, int64(1_780_933))
	field(1_780_925, "file", nil, 1, int64(1_780_934))
	for i, blob := range []struct {
		name string
		size int64
	}{{"notes.final.pdf", 2048}, {".hidden", 7}} {
		blobID := int64(1_780_941 + i)
		testdb.Insert(t, e.db, "active_storage_blobs", map[string]any{"id": blobID, "key": "go-web-downloads-" + itoa(blobID),
			"filename": blob.name, "byte_size": blob.size, "service_name": "test", "created_at": testNow})
		testdb.Insert(t, e.db, "active_storage_attachments", map[string]any{"id": int64(1_780_951 + i), "name": "files",
			"record_type": "PurchaseCustomField", "record_id": int64(1_780_925), "blob_id": blobID, "created_at": testNow})
	}
	want := `[{"custom_field_id":"` + e.ids.Encrypt(1_780_932) + `","type":"longAnswer","value":""},` +
		`{"custom_field_id":"` + e.ids.Encrypt(1_780_933) + `","type":null,"value":true},` +
		`{"custom_field_id":"` + e.ids.Encrypt(1_780_934) + `","type":"fileUpload","files":[` +
		`{"name":"notes.final","size":2048,"extension":"PDF"},{"name":".hidden","size":7,"extension":""}]}]`
	if got := rails.EncodeJSON(e.purchaseHash(token).Value("purchase_custom_fields")); got != want {
		t.Errorf("custom fields\n got %s\nwant %s", got, want)
	}
}

func TestACallShowsItsTimesAndLink(t *testing.T) {
	e := newPageEnv(t)
	token := e.purchase(productID, map[string]any{"price_cents": 500}, nil)
	start := time.Date(2026, 11, 20, 15, 30, 0, 0, time.UTC)
	testdb.Insert(t, e.db, "calls", map[string]any{"id": int64(1_780_961), "purchase_id": nextPurchase, "start_time": start,
		"end_time": start.Add(30 * time.Minute), "call_url": "", "created_at": testNow, "updated_at": testNow})
	if got := rails.EncodeJSON(e.purchaseHash(token).Value("call")); got != `{"start_time":"2026-11-20T15:30:00Z","end_time":"2026-11-20T16:00:00Z","url":null}` {
		t.Errorf("call %s", got)
	}
	e.db.Exec("UPDATE calls SET call_url = 'https://zoom.example.com/j/1' WHERE id = ?", int64(1_780_961))
	if got := e.purchaseHash(token).Value("call").(*rails.Hash).Value("url"); got != "https://zoom.example.com/j/1" {
		t.Errorf("call url %v", got)
	}
}

func TestAMembershipsPageDescribesItsSubscription(t *testing.T) {
	e := newPageEnv(t)
	sub := subscriptionID + 40
	testdb.Insert(t, e.db, "subscriptions", map[string]any{"id": sub, "link_id": productID, "user_id": buyerID, "created_at": testNow, "updated_at": testNow})
	token := e.purchase(productID, map[string]any{"price_cents": 500, "email": "buyer@example.com", "subscription_id": sub,
		"flags": purchaseIsOriginalSubscription, "succeeded_at": testNow.Add(-60 * 24 * time.Hour)}, nil)
	original := nextPurchase
	charge := func(at time.Time, email string, extra map[string]any) int64 {
		nextPurchase++
		row := map[string]any{"id": nextPurchase, "link_id": productID, "seller_id": sellerID, "purchaser_id": buyerID, "subscription_id": sub,
			"purchase_state": "successful", "price_cents": 500, "email": email, "succeeded_at": at}
		for k, v := range extra {
			row[k] = v
		}
		testdb.Insert(t, e.db, "purchases", row)
		return nextPurchase
	}

	membership := `{"has_active_subscription":true,"subscription_id":"` + e.ids.Encrypt(sub) + `","is_subscription_ended":false,` +
		`"is_installment_plan_completed":false,"is_subscription_cancelled_or_failed":false,"is_alive_or_restartable":true,` +
		`"in_free_trial":false,"is_installment_plan":false}`
	purchase := e.purchaseHash(token)
	if got := rails.EncodeJSON(purchase.Value("membership")); got != membership {
		t.Errorf("membership\n got %s\nwant %s", got, membership)
	}
	if purchase.Value("receipt_purchase_id") != e.ids.Encrypt(original) || purchase.Value("has_invoice") != true {
		t.Errorf("receipt %v invoice %v", purchase.Value("receipt_purchase_id"), purchase.Value("has_invoice"))
	}

	// The receipt is the latest charge the buyer paid under the same email.
	renewal := charge(testNow.Add(-30*24*time.Hour), "buyer@example.com", nil)
	charge(testNow.Add(-20*24*time.Hour), "buyer@example.com", map[string]any{"stripe_refunded": true})
	charge(testNow.Add(-10*24*time.Hour), "buyer@example.com", map[string]any{"purchase_state": "failed"})
	if got := e.purchaseHash(token).Value("receipt_purchase_id"); got != e.ids.Encrypt(renewal) {
		t.Errorf("receipt after a renewal: %v", got)
	}
	charge(testNow.Add(-5*24*time.Hour), "other@example.com", nil)
	if got := e.purchaseHash(token).Value("receipt_purchase_id"); got != e.ids.Encrypt(original) {
		t.Errorf("receipt after a charge under another email: %v", got)
	}

	// Cancelled by the seller, in a free trial. A cancelled installment plan loses access.
	e.db.Exec("UPDATE subscriptions SET cancelled_at = ?, free_trial_ends_at = ?, flags = ? WHERE id = ?",
		testNow.Add(-time.Hour), testNow.Add(24*time.Hour), subscriptionInstallmentPlan, sub)
	if w := e.page(token, nil); w.Code != http.StatusFound || e.railsHit != nil {
		t.Fatalf("cancelled installment plan: %d", w.Code)
	}
	e.db.Exec("UPDATE subscriptions SET flags = 0 WHERE id = ?", sub)
	membership = `{"has_active_subscription":false,"subscription_id":"` + e.ids.Encrypt(sub) + `","is_subscription_ended":false,` +
		`"is_installment_plan_completed":false,"is_subscription_cancelled_or_failed":true,"is_alive_or_restartable":false,` +
		`"in_free_trial":true,"is_installment_plan":false}`
	if got := rails.EncodeJSON(e.purchaseHash(token).Value("membership")); got != membership {
		t.Errorf("cancelled by the seller\n got %s\nwant %s", got, membership)
	}
	e.db.Exec("UPDATE subscriptions SET cancelled_at = ?, flags = ? WHERE id = ?", testNow.Add(time.Hour), subscriptionCancelledByBuyer, sub)
	if got := e.purchaseHash(token).Value("membership").(*rails.Hash); got.Value("is_alive_or_restartable") != true ||
		got.Value("has_active_subscription") != false {
		t.Errorf("pending cancellation by the buyer %s", rails.EncodeJSON(got))
	}

	// A free charge outside a trial asks renews_free?, which Rails prices.
	e.db.Exec("UPDATE purchases SET price_cents = 0, shipping_cents = 0, email = 'buyer@example.com' WHERE subscription_id = ?", sub)
	if e.page(token, nil); e.railsHit == nil {
		t.Error("a free membership charge was rendered")
	}
}

func TestACompletedInstallmentPlanCountsItsCharges(t *testing.T) {
	e := newPageEnv(t)
	sub := subscriptionID + 41
	testdb.Insert(t, e.db, "subscriptions", map[string]any{"id": sub, "link_id": productID, "user_id": buyerID, "flags": subscriptionInstallmentPlan,
		"charge_occurrence_count": 2, "created_at": testNow, "updated_at": testNow})
	token := e.purchase(productID, map[string]any{"price_cents": 500, "subscription_id": sub, "flags": purchaseIsOriginalSubscription}, nil)
	plan := func() any {
		return e.purchaseHash(token).Value("membership").(*rails.Hash).Value("is_installment_plan_completed")
	}
	if got := plan(); got != false {
		t.Errorf("one of two charges: %v", got)
	}
	nextPurchase++
	testdb.Insert(t, e.db, "purchases", map[string]any{"id": nextPurchase, "link_id": productID, "seller_id": sellerID, "subscription_id": sub,
		"purchase_state": "successful", "price_cents": 500})
	if got := plan(); got != true {
		t.Errorf("both charges: %v", got)
	}
}

func TestARecurringChargeShowsItsOriginalPurchasesLicense(t *testing.T) {
	e := newPageEnv(t)
	e.db.Exec("UPDATE links SET flags = flags | ? WHERE id = ?", productIsLicensed, productID)
	defer e.db.Exec("UPDATE links SET flags = flags & ~? WHERE id = ?", productIsLicensed, productID)
	sub := subscriptionID + 42
	testdb.Insert(t, e.db, "subscriptions", map[string]any{"id": sub, "link_id": productID, "user_id": buyerID, "created_at": testNow, "updated_at": testNow})
	e.purchase(productID, map[string]any{"price_cents": 500, "subscription_id": sub, "flags": purchaseIsOriginalSubscription}, nil)
	testdb.Insert(t, e.db, "licenses", map[string]any{"id": int64(1_780_971), "link_id": productID, "purchase_id": nextPurchase,
		"serial": "ORIG-1234", "created_at": testNow, "updated_at": testNow})
	token := e.purchase(productID, map[string]any{"price_cents": 500, "subscription_id": sub}, nil)
	w := e.page(token, nil)
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("status %d, rails %v", w.Code, e.railsHit != nil)
	}
	license := pageProps(t, w.Body.String()).Value("content").(*rails.Hash).Value("license")
	if got := rails.EncodeJSON(license); got != `{"license_key":"ORIG-1234","is_multiseat_license":false,"seats":1}` {
		t.Errorf("license %s", got)
	}
}
