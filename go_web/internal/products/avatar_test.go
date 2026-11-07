package products

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
	"github.com/antiwork/gumroad/go_web/internal/storage"
)

const (
	avatarUpload  = "https://gumroad-public-storage.s3.amazonaws.com/avatars/1790001"
	avatarResized = "https://public-files.gumroad.com/avatars/1790001/resized"
	avatarJob     = `"lock":"until_executing","args":[1790001],"class":"GenerateAvatarVariantJob"`
)

type missingFiles struct{}

func (missingFiles) Exists(context.Context, string) (bool, error) { return false, nil }

// addAvatar gives userID an avatar of contentType, with its 400x400 variant when resized is
// set. Its rows take the ids id to id+4.
func addAvatar(t *testing.T, userID, id int64, contentType string, resized bool) {
	conn := testdb.Open(t)
	key := "avatars/" + itoa(userID)
	addBlob(t, conn, id, key, "a.png", contentType, "{}")
	addAttachment(t, conn, id+1, "avatar", "User", userID, id)
	if !resized {
		return
	}
	testdb.Insert(t, conn, "active_storage_variant_records", map[string]any{"id": id + 2, "blob_id": id,
		"variation_digest": storage.VariantDigest("a.png", contentType, 400, 400)})
	addBlob(t, conn, id+3, key+"/resized", "a.png", contentType, "{}")
	addAttachment(t, conn, id+4, "image", "ActiveStorage::VariantRecord", id+2, id+3)
}

func addSellerAvatar(t *testing.T, contentType string, resized bool) {
	addAvatar(t, sellerID, 1_799_901, contentType, resized)
}

// sellerAvatar renders the page and returns the seller's avatar_url, which the shortcut icon
// shares.
func (e *testEnv) sellerAvatar(t *testing.T, headers map[string]string) string {
	t.Helper()
	w := e.get(host, "/l/guide", headers)
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	body := w.Body.String()
	avatar := pageProps(t, body)["product"].(map[string]any)["seller"].(map[string]any)["avatar_url"].(string)
	if !strings.Contains(body, `<link rel="shortcut icon" href="`+avatar+`"`) {
		t.Errorf("the shortcut icon isn't %s", avatar)
	}
	return avatar
}

// wantOneJob fails unless queue:low holds just the job that has want in it.
func wantOneJob(t *testing.T, queued []string, want string) {
	t.Helper()
	if len(queued) != 1 || !strings.Contains(queued[0], want) {
		t.Errorf("queue:low %v", queued)
	}
}

// avatar_url serves the upload and enqueues its resize instead of resizing in the request.
func TestASellerAvatarWithoutItsVariantQueuesIt(t *testing.T) {
	e := newTestEnv(t)
	jobs := sidekiqJobs(t, e)
	addSellerAvatar(t, "image/png", false)
	if avatar := e.sellerAvatar(t, e.dryRun(host, "/l/guide", testNow)); avatar != avatarUpload {
		t.Errorf("dry run avatar %s", avatar)
	}
	if jobs.Exists("queue:low") {
		t.Fatal("a dry run queued the variant")
	}
	if avatar := e.sellerAvatar(t, nil); avatar != avatarUpload {
		t.Errorf("avatar %s", avatar)
	}
	queued, _ := jobs.List("queue:low")
	wantOneJob(t, queued, avatarJob)
	// lock: :until_executing holds while that job waits.
	e.sellerAvatar(t, nil)
	if queued, _ := jobs.List("queue:low"); len(queued) != 1 {
		t.Errorf("%d jobs queued", len(queued))
	}
}

// A variant whose file is gone is the job's to replace too.
func TestASellerAvatarWhoseVariantFileIsGoneQueuesIt(t *testing.T) {
	e := newTestEnv(t)
	jobs := sidekiqJobs(t, e)
	e.config.Page.Avatars.Exists = missingFiles{}
	addSellerAvatar(t, "image/png", true)
	if avatar := e.sellerAvatar(t, nil); avatar != avatarUpload {
		t.Errorf("avatar %s", avatar)
	}
	queued, _ := jobs.List("queue:low")
	wantOneJob(t, queued, avatarJob)
}

func TestAResizedSellerAvatarServesItsVariant(t *testing.T) {
	e := newTestEnv(t)
	jobs := sidekiqJobs(t, e)
	addSellerAvatar(t, "image/png", true)
	if avatar := e.sellerAvatar(t, nil); avatar != avatarResized {
		t.Errorf("avatar %s", avatar)
	}
	if jobs.Exists("queue:low") {
		t.Error("a resized avatar queued its variant")
	}
}

// avatar.variant raises for a type it can't resize, and avatar_url's rescue serves the upload.
func TestAnInvariableSellerAvatarServesTheUpload(t *testing.T) {
	e := newTestEnv(t)
	addSellerAvatar(t, "image/svg+xml", false)
	if avatar := e.sellerAvatar(t, nil); avatar != avatarUpload {
		t.Errorf("avatar %s", avatar)
	}
}

func TestASellerAvatarWithoutItsVariantOrSidekiqGoesToRails(t *testing.T) {
	e := newTestEnv(t)
	addSellerAvatar(t, "image/png", false)
	e.render(t, nil, "avatar variant push")
}

// show's set_favicon_meta_tags reads the avatar ahead of the checkout redirect, in every format.
func TestWantedQueuesTheSellersAvatarVariant(t *testing.T) {
	for _, target := range []string{"/l/guide?wanted=true", "/l/guide.json?wanted=true"} {
		t.Run(target, func(t *testing.T) {
			e := newTestEnv(t)
			jobs := sidekiqJobs(t, e)
			addSellerAvatar(t, "image/png", false)
			if w := e.get(host, target, nil); w.Code != http.StatusFound {
				t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
			}
			queued, _ := jobs.List("queue:low")
			wantOneJob(t, queued, avatarJob)
		})
	}
}

// The signed-in props, and the visitor's avatar in them, are read only when the page renders.
func TestASignedInVisitorsAvatarQueuesWithThePage(t *testing.T) {
	e := newTestEnv(t)
	jobs := sidekiqJobs(t, e)
	addBuyer(t, testdb.Open(t), nil)
	addAvatar(t, buyerID, 1_799_911, "image/png", false)
	if w := e.get(host, "/l/guide?wanted=true", e.signedIn(buyerID, nil)); w.Code != http.StatusFound {
		t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	if queued, _ := jobs.List("queue:low"); len(queued) != 0 {
		t.Fatalf("the redirect queued %v", queued)
	}
	if w := e.get(host, "/l/guide", e.signedIn(buyerID, nil)); w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	queued, _ := jobs.List("queue:low")
	wantOneJob(t, queued, `"args":[1796001],"class":"GenerateAvatarVariantJob"`)
}
