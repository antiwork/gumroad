package downloads

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"

	"github.com/antiwork/gumroad/go_web/internal/pages"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
)

const (
	videoID      = int64(1_780_901)
	otherVideoID = int64(1_780_902)
)

// newJobsPageEnv is newPageEnv with a Sidekiq client on a Redis the test reads.
func newJobsPageEnv(t *testing.T) (*testEnv, *miniredis.Miniredis) {
	t.Helper()
	mr := miniredis.RunT(t)
	e := newPageEnvWith(t, func(c *PageConfig) {
		c.Sidekiq = &sidekiq.Client{Redis: redis.NewClient(&redis.Options{Addr: mr.Addr()}), Now: func() time.Time { return testNow }}
	})
	return e, mr
}

func (e *testEnv) video(id int64) {
	e.t.Helper()
	testdb.Insert(e.t, e.db, "product_files", map[string]any{"id": id, "link_id": productID, "filetype": "mp4", "filegroup": "video",
		"width": 1920, "height": 1080, "position": 2, "created_at": testNow, "updated_at": testNow})
}

func (e *testEnv) transcode(id, file int64, deleted bool) {
	e.t.Helper()
	row := map[string]any{"id": id, "streamable_type": "ProductFile", "streamable_id": file, "state": "completed",
		"original_video_key": "o", "transcoded_video_key": "t", "created_at": testNow, "updated_at": testNow,
		"last_accessed_at": testNow.Add(-48 * time.Hour)}
	if deleted {
		row["deleted_at"] = testNow.Add(-time.Hour)
	}
	testdb.Insert(e.t, e.db, "transcoded_videos", row)
}

func TestAVideoPageMarksItsTranscodesAccessedAndRegeneratesDeletedOnes(t *testing.T) {
	e, mr := newJobsPageEnv(t)
	e.video(videoID)
	e.video(otherVideoID)
	e.transcode(1_780_911, videoID, false)
	e.transcode(1_780_912, otherVideoID, true)
	token := e.purchase(productID, map[string]any{"price_cents": 500}, nil)

	// A dry run reads the same rows and writes none of them.
	sign := map[string]string{"X-Go-Web-Dry-Run": pages.SignDryRun(pages.DryRunKey(testSecretKeyBase), "GET", "gumroad.com", "/d/"+token, testNow)}
	if w := e.page(token, sign); w.Code != http.StatusOK {
		t.Fatalf("dry run: %d %s", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	if jobs, _ := mr.List("queue:default"); len(jobs) != 0 {
		t.Errorf("a dry run pushed %v", jobs)
	}

	w := e.page(token, nil)
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("status %d, rails %v: %s", w.Code, e.railsHit != nil, w.Header().Get("X-Go-Web-Fallback"))
	}
	var alive, deleted time.Time
	e.db.QueryRow("SELECT last_accessed_at FROM transcoded_videos WHERE id = 1780911").Scan(&alive)
	e.db.QueryRow("SELECT last_accessed_at FROM transcoded_videos WHERE id = 1780912").Scan(&deleted)
	if !alive.Equal(testNow) || deleted.Equal(testNow) {
		t.Errorf("last_accessed_at: alive %v, deleted %v", alive, deleted)
	}
	jobs, _ := mr.List("queue:default")
	if len(jobs) != 1 {
		t.Fatalf("jobs %v", jobs)
	}
	var job struct {
		Class string `json:"class"`
		Args  []any  `json:"args"`
	}
	json.Unmarshal([]byte(jobs[0]), &job)
	if job.Class != "TranscodeVideoForStreamingWorker" || len(job.Args) != 2 || job.Args[0] != float64(otherVideoID) || job.Args[1] != "ProductFile" {
		t.Errorf("job %s", jobs[0])
	}

	// The page renders the video natively.
	items := pageProps(t, w.Body.String()).Value("content").(*rails.Hash).Value("content_items").([]any)
	last := items[len(items)-1].(*rails.Hash)
	if last.Value("stream_url") == nil || rails.EncodeJSON(last.Value("width")) != "1920" {
		t.Errorf("video item %s", rails.EncodeJSON(last))
	}
}

func TestDeletedTranscodesAreRegeneratedFiveMinutesApart(t *testing.T) {
	e, mr := newJobsPageEnv(t)
	e.video(videoID)
	e.video(otherVideoID)
	e.transcode(1_780_911, videoID, true)
	e.transcode(1_780_912, otherVideoID, true)
	token := e.purchase(productID, map[string]any{"price_cents": 500}, nil)
	if w := e.page(token, nil); w.Code != http.StatusOK {
		t.Fatalf("status %d: %s", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	queued, _ := mr.List("queue:default")
	scheduled, _ := mr.ZMembers("schedule")
	if len(queued) != 1 || len(scheduled) != 1 {
		t.Fatalf("queued %v, scheduled %v", queued, scheduled)
	}
	if score, _ := mr.ZScore("schedule", scheduled[0]); score != float64(testNow.Add(transcodeSpacing).Unix()) {
		t.Errorf("scheduled at %v", score)
	}
}

func TestPagesThatWouldEnqueueWithoutAClientGoToRails(t *testing.T) {
	e := newPageEnv(t)
	e.video(videoID)
	e.transcode(1_780_911, videoID, true)
	token := e.purchase(productID, map[string]any{"price_cents": 500}, nil)
	if e.page(token, nil); e.railsHit == nil {
		t.Error("a page needing a job without a Sidekiq client was rendered")
	}
}

func TestADeletedStampedPDFIsStampedAgain(t *testing.T) {
	e, mr := newJobsPageEnv(t)
	e.db.Exec("UPDATE product_files SET flags = flags | 16 WHERE id = ?", fileID)
	defer e.db.Exec("UPDATE product_files SET flags = flags & ~16 WHERE id = ?", fileID)
	token := e.purchase(productID, map[string]any{"price_cents": 500}, nil)
	id := nextPurchase
	w := e.page(token, nil)
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("status %d, rails %v", w.Code, e.railsHit != nil)
	}
	items := pageProps(t, w.Body.String()).Value("content").(*rails.Hash).Value("content_items").([]any)
	if pdf := items[0].(*rails.Hash); pdf.Value("pdf_stamp_enabled") != true || pdf.Value("processing") != true {
		t.Errorf("stamped file %s", rails.EncodeJSON(pdf))
	}
	// Never stamped: the purchase's own stamping job makes it, so the page enqueues nothing.
	if jobs, _ := mr.List("queue:long"); len(jobs) != 0 {
		t.Errorf("jobs before any stamped PDF was deleted: %v", jobs)
	}
	testdb.Insert(t, e.db, "stamped_pdfs", map[string]any{"id": int64(1_780_921), "url_redirect_id": id, "product_file_id": fileID,
		"created_at": testNow, "updated_at": testNow, "deleted_at": testNow})
	if w := e.page(token, nil); w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("status %d, rails %v", w.Code, e.railsHit != nil)
	}
	jobs, _ := mr.List("queue:long")
	if len(jobs) != 1 {
		t.Fatalf("jobs %v", jobs)
	}
	var job struct {
		Class              string `json:"class"`
		Args               []any  `json:"args"`
		UniqueAcrossQueues bool   `json:"unique_across_queues"`
	}
	json.Unmarshal([]byte(jobs[0]), &job)
	if job.Class != "StampPdfForPurchaseJob" || len(job.Args) != 1 || job.Args[0] != float64(id) || !job.UniqueAcrossQueues {
		t.Errorf("job %s", jobs[0])
	}
	// Its lock holds the next view's push back until it has run.
	e.page(token, nil)
	if jobs, _ := mr.List("queue:long"); len(jobs) != 1 {
		t.Errorf("jobs after a second view: %d", len(jobs))
	}
}

func contentProp(t *testing.T, e *testEnv, token, key string) any {
	t.Helper()
	w := e.page(token, nil)
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("status %d, rails %v: %s", w.Code, e.railsHit != nil, w.Header().Get("X-Go-Web-Fallback"))
	}
	return pageProps(t, w.Body.String()).Value("content").(*rails.Hash).Value(key)
}

func TestTheDiscordPropFollowsTheIntegrationTheBuyerGets(t *testing.T) {
	e := newPageEnv(t)
	token := e.purchase(productID, map[string]any{"price_cents": 500}, nil)
	id := nextPurchase
	if got := contentProp(t, e, token, "discord"); got != nil {
		t.Errorf("discord without an integration: %s", rails.EncodeJSON(got))
	}
	testdb.Insert(t, e.db, "integrations", map[string]any{"id": int64(1_780_931), "type": "DiscordIntegration", "created_at": testNow, "updated_at": testNow})
	testdb.Insert(t, e.db, "product_integrations", map[string]any{"id": int64(1_780_932), "product_id": productID, "integration_id": int64(1_780_931),
		"created_at": testNow, "updated_at": testNow})
	if got := rails.EncodeJSON(contentProp(t, e, token, "discord")); got != `{"connected":false}` {
		t.Errorf("discord, not connected: %s", got)
	}
	testdb.Insert(t, e.db, "purchase_integrations", map[string]any{"id": int64(1_780_933), "purchase_id": id, "integration_id": int64(1_780_931),
		"discord_user_id": "42", "created_at": testNow, "updated_at": testNow})
	if got := rails.EncodeJSON(contentProp(t, e, token, "discord")); got != `{"connected":true}` {
		t.Errorf("discord, connected: %s", got)
	}

	// A purchased variant's integrations replace the product's, even when it has none. It is
	// deleted, so the product's own content still renders.
	testdb.Insert(t, e.db, "variant_categories", map[string]any{"id": int64(1_780_801), "link_id": productID, "title": "Tier"})
	testdb.Insert(t, e.db, "base_variants", map[string]any{"id": int64(1_780_811), "variant_category_id": int64(1_780_801), "name": "Basic",
		"type": "Variant", "price_difference_cents": 0, "deleted_at": testNow})
	testdb.Insert(t, e.db, "base_variants_purchases", map[string]any{"id": int64(1_780_821), "purchase_id": id, "base_variant_id": int64(1_780_811)})
	if got := contentProp(t, e, token, "discord"); got != nil {
		t.Errorf("discord for a variant without the integration: %s", rails.EncodeJSON(got))
	}
}

func TestTheCommunityChatURLSendsTheBuyerToSignInOrUp(t *testing.T) {
	e := newPageEnv(t)
	e.db.Exec("UPDATE links SET flags = flags | ? WHERE id = ?", productCommunityChatEnabled, productID)
	defer e.db.Exec("UPDATE links SET flags = flags & ~? WHERE id = ?", productCommunityChatEnabled, productID)
	token := e.purchase(productID, map[string]any{"price_cents": 500, "email": "buyer@example.com"}, nil)
	if got := contentProp(t, e, token, "community_chat_url"); got != nil {
		t.Errorf("community chat without a community: %v", got)
	}
	community := int64(1_780_941)
	testdb.Insert(t, e.db, "communities", map[string]any{"id": community, "resource_type": "Link", "resource_id": productID, "seller_id": sellerID,
		"created_at": testNow, "updated_at": testNow})
	path := "%2Fcommunities%2F1780001%2F" + rails.CGIEscape(e.ids.Encrypt(community))
	if got := contentProp(t, e, token, "community_chat_url"); got != "/login?email=buyer%40example.com&next="+path {
		t.Errorf("community chat for a purchaser: %v", got)
	}
	guest := e.purchase(productID, map[string]any{"price_cents": 500, "email": "buyer@example.com", "purchaser_id": nil}, nil)
	if got := contentProp(t, e, guest, "community_chat_url"); got != "/signup?email=buyer%40example.com&next="+path {
		t.Errorf("community chat for a guest: %v", got)
	}
	// The purchaser signed in goes straight to the community.
	w := e.pageAs(token, buyerID)
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("signed in: status %d, rails %v: %s", w.Code, e.railsHit != nil, w.Header().Get("X-Go-Web-Fallback"))
	}
	if got := pageProps(t, w.Body.String()).Value("content").(*rails.Hash).Value("community_chat_url"); got != "/communities/1780001/"+e.ids.Encrypt(community) {
		t.Errorf("community chat signed in: %v", got)
	}
}

func TestTheSellersOwnVideoPageGoesToRails(t *testing.T) {
	e, _ := newJobsPageEnv(t)
	e.video(videoID)
	token := e.purchase(productID, map[string]any{"price_cents": 500, "purchaser_id": sellerID}, nil)
	// video_transcoding_info reads has_been_transcoded? for the seller.
	if e.pageAs(token, sellerID); e.railsHit == nil {
		t.Error("the seller's own video page was rendered")
	}
	// Anyone else gets none.
	other := e.purchase(productID, map[string]any{"price_cents": 500}, nil)
	if w := e.pageAs(other, buyerID); w.Code != http.StatusOK || e.railsHit != nil {
		t.Errorf("the buyer's video page: status %d, rails %v: %s", w.Code, e.railsHit != nil, w.Header().Get("X-Go-Web-Fallback"))
	}
}

func TestABundleMembersReceiptIsTheBundlePurchase(t *testing.T) {
	e := newPageEnv(t)
	bundle := e.purchase(productID, map[string]any{"price_cents": 0, "shipping_cents": 0, "email": "buyer@example.com"}, nil)
	_ = bundle
	bundleID := nextPurchase
	token := e.purchase(productID, map[string]any{"price_cents": 500, "email": "buyer@example.com", "flags": purchaseIsBundleProduct}, nil)
	testdb.Insert(t, e.db, "bundle_product_purchases", map[string]any{"id": int64(1_780_951), "bundle_purchase_id": bundleID,
		"product_purchase_id": nextPurchase, "created_at": testNow, "updated_at": testNow})
	purchase := func() *rails.Hash {
		t.Helper()
		w := e.page(token, nil)
		if w.Code != http.StatusOK || e.railsHit != nil {
			t.Fatalf("status %d, rails %v: %s", w.Code, e.railsHit != nil, w.Header().Get("X-Go-Web-Fallback"))
		}
		return pageProps(t, w.Body.String()).Value("purchase").(*rails.Hash)
	}
	got := purchase()
	if got.Value("receipt_purchase_id") != e.ids.Encrypt(bundleID) || got.Value("has_invoice") != false || got.Value("free") != false {
		t.Errorf("bundle member %s", rails.EncodeJSON(got))
	}
	// Another email keeps the member's own receipt.
	e.db.Exec("UPDATE purchases SET email = 'other@example.com' WHERE id = ?", bundleID)
	if got := purchase(); got.Value("receipt_purchase_id") != e.ids.Encrypt(nextPurchase) || got.Value("has_invoice") != true {
		t.Errorf("bundle member, other email %s", rails.EncodeJSON(got))
	}
}
