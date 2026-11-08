package products

import (
	"database/sql"
	"html"
	"net/http"
	"slices"
	"strings"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
)

func addBlob(t *testing.T, conn *sql.DB, id int64, key, filename, contentType, metadata string) {
	testdb.Insert(t, conn, "active_storage_blobs", map[string]any{"id": id, "key": key, "filename": filename,
		"content_type": contentType, "metadata": metadata, "service_name": "amazon", "byte_size": 1, "created_at": testNow})
}

func addAttachment(t *testing.T, conn *sql.DB, id int64, name, recordType string, recordID, blobID int64) {
	testdb.Insert(t, conn, "active_storage_attachments", map[string]any{"id": id, "name": name, "record_type": recordType,
		"record_id": recordID, "blob_id": blobID, "created_at": testNow})
}

// addVideoCover gives the product an uploaded video cover whose analyzer metadata is metadata,
// with a preview image whose resized copy for digest is processed when poster is true.
func addVideoCover(t *testing.T, conn *sql.DB, metadata, digest string, poster bool) {
	blob := func(id int64, key, filename, contentType, metadata string) {
		addBlob(t, conn, id, key, filename, contentType, metadata)
	}
	attach := func(id int64, name, recordType string, recordID, blobID int64) {
		addAttachment(t, conn, id, name, recordType, recordID, blobID)
	}
	testdb.Insert(t, conn, "asset_previews", map[string]any{"id": int64(1_793_101), "link_id": productID, "guid": "video-guid",
		"position": 0, "created_at": testNow, "updated_at": testNow})
	blob(1_793_201, "videos/original", "clip.mp4", "video/mp4", metadata)
	attach(1_793_301, "file", "AssetPreview", 1_793_101, 1_793_201)
	blob(1_793_202, "posters/preview", "clip.jpg", "image/jpeg", "{}")
	attach(1_793_302, "preview_image", "ActiveStorage::Blob", 1_793_201, 1_793_202)
	if !poster {
		return
	}
	testdb.Insert(t, conn, "active_storage_variant_records", map[string]any{"id": int64(1_793_401), "blob_id": int64(1_793_202),
		"variation_digest": digest})
	blob(1_793_203, "posters/retina", "clip.jpg", "image/jpeg", "{}")
	attach(1_793_303, "image", "ActiveStorage::VariantRecord", 1_793_401, 1_793_203)
}

func TestAVideoCoverRendersWithItsPoster(t *testing.T) {
	const video, poster = "https://public-files.gumroad.com/videos/original", "https://public-files.gumroad.com/posters/retina"
	for _, c := range []struct {
		name, metadata, digest string
		cover                  string
		width, height          string
	}{
		// The video analyzer writes Floats; a wide video's poster is resized to RETINA_DISPLAY_WIDTH.
		{"a wide video", `{"width":1920.0,"height":1080.0,"duration":3.2,"analyzed":true}`, "WX6OQ3hf/g9WoAI2n/sUdFF1vxA=",
			`"width":670,"height":376,"native_width":1920.0,"native_height":1080.0`, "670", "376"},
		// Narrower than the display width, its Float width is the display width and the poster's bound.
		{"a narrow video", `{"width":640.0,"height":360.0,"analyzed":true}`, "Fb328hWv8t5dUbSIMy4sjmj+tMk=",
			`"width":640.0,"height":360,"native_width":640.0,"native_height":360.0`, "640.0", "360"},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			addVideoCover(t, testdb.Open(t), c.metadata, c.digest, true)
			w := e.get(host, "/l/guide", nil)
			if w.Code != http.StatusOK {
				t.Fatalf("status %d, fallback %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
			}
			body := w.Body.String()
			page := html.UnescapeString(dataPage.FindStringSubmatch(body)[1])
			if want := `"covers":[{"url":"` + video + `","original_url":"` + video + `","thumbnail":"` + poster +
				`","id":"video-guid","type":"video","filetype":"mp4",` + c.cover + `}],"main_cover_id":"video-guid"`; !strings.Contains(page, want) {
				t.Errorf("want %s\nin %s", want, page)
			}
			for _, want := range []string{
				`<meta property="og:image" content="` + poster + `"`,
				`<meta property="twitter:card" content="player"`,
				`<meta property="twitter:image" content="https://gumroad.com/assets/icon.png"`,
				`<meta property="twitter:player" content="` + video + `"`,
				`<meta property="twitter:player:width" content="` + c.width + `"`,
				`<meta property="twitter:player:height" content="` + c.height + `"`,
			} {
				if !strings.Contains(body, want) {
					t.Errorf("missing %s", want)
				}
			}
			if strings.Contains(body, `rel="preload" as="image"`) {
				t.Error("a video cover is preloaded as an image")
			}
			// video_poster_url writes the persisted poster back.
			if !slices.Contains(e.cache.writes, "attachment_1793301_poster_url") {
				t.Errorf("cache writes %v", e.cache.writes)
			}
		})
	}
}

// preview_width and preview_height are nil for a video without its size, and their tags have
// no content.
func TestAVideoCoverWithoutItsSize(t *testing.T) {
	e := newTestEnv(t)
	addVideoCover(t, testdb.Open(t), `{"analyzed":true}`, "WX6OQ3hf/g9WoAI2n/sUdFF1vxA=", true)
	w := e.get(host, "/l/guide", nil)
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	for _, want := range []string{
		`<meta property="twitter:player" content="https://public-files.gumroad.com/videos/original"`,
		`<meta property="twitter:player:width" inertia="meta-property-twitter-player-width">`,
		`<meta property="twitter:player:height" inertia="meta-property-twitter-player-height">`,
	} {
		if !strings.Contains(w.Body.String(), want) {
			t.Errorf("missing %s", want)
		}
	}
}

// A blob with two preview images takes the one Rails' has_one statement returns first: the
// uniqueness index's first, by blob, not the lowest attachment id.
func TestAVideoCoverWithTwoPreviewImages(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	addVideoCover(t, conn, `{"width":1920.0,"height":1080.0}`, "WX6OQ3hf/g9WoAI2n/sUdFF1vxA=", true)
	addBlob(t, conn, 1_793_204, "posters/other", "other.jpg", "image/jpeg", "{}")
	addAttachment(t, conn, 1_793_300, "preview_image", "ActiveStorage::Blob", 1_793_201, 1_793_204)
	w := e.get(host, "/l/guide", nil)
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	if !strings.Contains(html.UnescapeString(w.Body.String()), `"thumbnail":"https://public-files.gumroad.com/posters/retina","id":"video-guid"`) {
		t.Error("poster")
	}
}

// video_poster_url never makes a poster in the request: without a cached or persisted one it
// shows none and enqueues GenerateVideoPosterWorker, unless Rails' failure sentinel is cached.
func TestAVideoCoverWithoutItsPosterQueuesIt(t *testing.T) {
	e := newTestEnv(t)
	jobs := sidekiqJobs(t, e)
	addVideoCover(t, testdb.Open(t), `{"width":1920.0,"height":1080.0}`, "WX6OQ3hf/g9WoAI2n/sUdFF1vxA=", false)
	const key = "attachment_1793301_poster_url"
	// The default share image stays.
	noPoster := func(headers map[string]string) {
		t.Helper()
		w := e.get(host, "/l/guide", headers)
		if w.Code != http.StatusOK || !strings.Contains(html.UnescapeString(w.Body.String()), `"thumbnail":null,"id":"video-guid"`) ||
			!strings.Contains(w.Body.String(), `<meta property="og:image" content="https://assets.gumroad.com/images/opengraph_image.png"`) {
			t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
		}
	}
	e.cache.values[key] = ""
	noPoster(nil)
	if jobs.Exists("queue:low") {
		t.Fatal("the failure sentinel queued the poster")
	}
	delete(e.cache.values, key)
	noPoster(e.dryRun(host, "/l/guide", testNow))
	if jobs.Exists("queue:low") {
		t.Fatal("a dry run queued the poster")
	}
	noPoster(nil)
	queued, _ := jobs.List("queue:low")
	if len(queued) != 1 || !strings.Contains(queued[0], `"lock":"until_executed","args":[1793101],"class":"GenerateVideoPosterWorker"`) {
		t.Errorf("queue:low %v", queued)
	}
	// A poster go_web cached earlier is enough.
	e.cache.values[key] = "https://public-files.gumroad.com/posters/cached"
	if w := e.get(host, "/l/guide", nil); w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "posters/cached") {
		t.Errorf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
}

func TestAVideoCoverWithoutItsPosterOrSidekiqGoesToRails(t *testing.T) {
	e := newTestEnv(t)
	addVideoCover(t, testdb.Open(t), `{"width":1920.0,"height":1080.0}`, "WX6OQ3hf/g9WoAI2n/sUdFF1vxA=", false)
	e.render(t, nil, "video poster push")
}

// psychOembed is YAML.dump of an OEmbedFinder YouTube result, as the oembed column holds it.
const psychOembed = "---\nhtml: '<iframe width=\"200\" height=\"113\" src=\"//www.youtube.com/embed/abc123?feature=oembed\"\n" +
	"  frameborder=\"0\" allow=\"accelerometer; autoplay; clipboard-write\" referrerpolicy=\"strict-origin-when-cross-origin\"\n" +
	"  allowfullscreen title=\"Tom &amp; Jerry: “the chase” #1\"></iframe>'\ninfo:\n" +
	"  thumbnail_url: \" https://i.ytimg.com/vi/abc123/hqdefault.jpg\\n\"\n  width: 200\n  height: 113\n"

func TestAnOembedCoverRendersItsPlayer(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	testdb.Insert(t, conn, "asset_previews", map[string]any{"id": int64(1_793_501), "link_id": productID, "guid": "player-guid",
		"position": 0, "oembed": psychOembed, "created_at": testNow, "updated_at": testNow})
	w := e.get(host, "/l/guide", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("status %d, fallback %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	body := w.Body.String()
	page := html.UnescapeString(dataPage.FindStringSubmatch(body)[1])
	// Nokogiri's iframe src, made absolute, with YouTube's API flag.
	player := `https://www.youtube.com/embed/abc123?feature=oembed\u0026enablejsapi=1`
	thumbnail := "https://i.ytimg.com/vi/abc123/hqdefault.jpg"
	if want := `"covers":[{"url":"` + player + `","original_url":"` + player + `","thumbnail":"` + thumbnail +
		`","id":"player-guid","type":"oembed","filetype":null,"width":200,"height":113,"native_width":200,"native_height":113}]`; !strings.Contains(page, want) {
		t.Errorf("want %s\nin %s", want, page)
	}
	for _, want := range []string{
		`<meta property="og:image" content="` + thumbnail + `"`,
		`<meta property="twitter:card" content="player"`,
		`<meta property="twitter:image" content="` + thumbnail + `"`,
		`<meta property="twitter:player" content="https://www.youtube.com/embed/abc123?feature=oembed&amp;enablejsapi=1"`,
		`<meta property="twitter:player:width" content="200"`,
		`<meta property="twitter:player:height" content="113"`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("missing %s", want)
		}
	}
	if strings.Contains(body, `rel="preload" as="image"`) {
		t.Error("a player is preloaded as an image")
	}
}

// A player without a safe thumbnail URL has a nil oembed_thumbnail_url: its twitter:image tag
// carries no content, in the HTML and in the head's meta JSON.
func TestAnOembedCoverWithoutAThumbnail(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	oembed := strings.Replace(psychOembed, "thumbnail_url: \" https://i.ytimg.com/vi/abc123/hqdefault.jpg\\n\"", "thumbnail_url: javascript:x", 1)
	testdb.Insert(t, conn, "asset_previews", map[string]any{"id": int64(1_793_501), "link_id": productID, "guid": "player-guid",
		"position": 0, "oembed": oembed, "created_at": testNow, "updated_at": testNow})
	w := e.get(host, "/l/guide", nil)
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("status %d, fallback %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	body := w.Body.String()
	for _, want := range []string{`<meta property="twitter:card" content="player"`,
		`<meta property="twitter:image" inertia="meta-property-twitter-image">`,
		`{"tagName":"meta","headKey":"meta-property-twitter-image","property":"twitter:image"}`} {
		if !strings.Contains(html.UnescapeString(body), want) {
			t.Errorf("missing %s", want)
		}
	}
}

func TestAnOembedCoverThisPortCannotReadGoesToRails(t *testing.T) {
	for name, raw := range map[string]string{
		"a Ruby tag":     "--- !ruby/hash:ActiveSupport::HashWithIndifferentAccess\nhtml: x\ninfo:\n  width: 1\n",
		"an unknown key": "---\nhtml: <iframe src=\"https://x.example.com\"></iframe>\ninfo:\n  width: 1\n  title: t\n",
		"no iframe":      "---\nhtml: <div></div>\ninfo:\n  width: 1\n",
		// Psych reads a plain 0o17 as a String, whose to_i is 0.
		"an octal width": "---\nhtml: <iframe src=\"https://x.example.com\"></iframe>\ninfo:\n  width: 0o17\n",
		// Addressable::URI.escape would rewrite the share image.
		"an escaped thumbnail": "---\nhtml: <iframe src=\"https://x.example.com\"></iframe>\ninfo:\n  thumbnail_url: https://i.example.com/a%20b.jpg\n  width: 1\n  height: 1\n",
	} {
		t.Run(name, func(t *testing.T) {
			e := newTestEnv(t)
			testdb.Insert(t, testdb.Open(t), "asset_previews", map[string]any{"id": int64(1_793_501), "link_id": productID, "guid": "g",
				"position": 0, "oembed": raw, "created_at": testNow, "updated_at": testNow})
			w := e.get(host, "/l/guide", e.dryRun(host, "/l/guide", testNow))
			if reason := w.Header().Get("X-Go-Web-Fallback"); w.Code != http.StatusNoContent || !strings.HasPrefix(reason, "oembed") {
				t.Errorf("%d %q", w.Code, reason)
			}
		})
	}
}

func TestAnUnsplashCoverRendersItsURL(t *testing.T) {
	e := newTestEnv(t)
	const photo = "https://images.unsplash.com/photo-1?w=1080"
	testdb.Insert(t, testdb.Open(t), "asset_previews", map[string]any{"id": int64(1_793_601), "link_id": productID, "guid": "photo-guid",
		"position": 0, "unsplash_url": photo, "created_at": testNow, "updated_at": testNow})
	w := e.get(host, "/l/guide", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("status %d, fallback %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	body := w.Body.String()
	page := html.UnescapeString(dataPage.FindStringSubmatch(body)[1])
	if want := `"covers":[{"url":"` + photo + `","original_url":"` + photo + `","thumbnail":null,"id":"photo-guid","type":"unsplash",` +
		`"filetype":null,"width":null,"height":null,"native_width":null,"native_height":null}]`; !strings.Contains(page, want) {
		t.Errorf("want %s\nin %s", want, page)
	}
	for _, want := range []string{
		`<meta property="og:image" content="` + html.EscapeString(photo) + `"`,
		`<meta property="twitter:card" content="summary_large_image"`,
		`<meta property="twitter:image" content="` + html.EscapeString(photo) + `"`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("missing %s", want)
		}
	}
	// file.image? is nil without a file, so nothing is preloaded.
	if strings.Contains(body, `rel="preload" as="image"`) {
		t.Error("an Unsplash cover is preloaded")
	}
}

// Covers tied on position and created_at come in the order Rails' statements return, which
// here, as for the tied covers seen in production, is by id.
func TestCoversTiedOnPositionAndTime(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	testdb.Insert(t, conn, "asset_previews", map[string]any{"id": int64(1_793_701), "link_id": productID, "guid": "first",
		"created_at": testNow, "updated_at": testNow})
	addBlob(t, conn, 1_793_801, "covers/first", "first.gif", "image/gif", `{"width":10,"height":10}`)
	addAttachment(t, conn, 1_793_901, "file", "AssetPreview", 1_793_701, 1_793_801)
	// An Unsplash cover has no file, and is still one of the tied previews.
	testdb.Insert(t, conn, "asset_previews", map[string]any{"id": int64(1_793_702), "link_id": productID, "guid": "second",
		"unsplash_url": "https://images.unsplash.com/photo", "created_at": testNow, "updated_at": testNow})
	w := e.get(host, "/l/guide", nil)
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	product := pageProps(t, w.Body.String())["product"].(map[string]any)
	covers := product["covers"].([]any)
	if len(covers) != 2 || covers[0].(map[string]any)["id"] != "first" || product["main_cover_id"] != "first" {
		t.Errorf("covers %v, main %v", covers, product["main_cover_id"])
	}
}

func TestACoverWithTwoFilesUsesTheLowerBlob(t *testing.T) {
	e := newTestEnv(t)
	addCover(t, true)
	conn := testdb.Open(t)
	// A second, later attachment of the same preview: has_one keeps the lower blob_id.
	testdb.Insert(t, conn, "active_storage_blobs", map[string]any{"id": int64(1_790_509), "key": "covers/other", "filename": "b.jpg",
		"content_type": "image/jpeg", "metadata": `{"width":10,"height":10}`, "service_name": "amazon_public", "byte_size": 1, "created_at": testNow})
	// Its attachment id is lower, so only blob_id order keeps the first file.
	testdb.Insert(t, conn, "active_storage_attachments", map[string]any{"id": int64(1_790_600), "name": "file",
		"record_type": "AssetPreview", "record_id": int64(1_790_401), "blob_id": int64(1_790_509), "created_at": testNow})
	w := e.get(host, "/l/guide", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("status %d, fallback %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	if page := html.UnescapeString(dataPage.FindStringSubmatch(w.Body.String())[1]); !strings.Contains(page, `"covers":[{"url":"https://public-files.gumroad.com/covers/retina"`) ||
		strings.Contains(page, "covers/other") {
		t.Errorf("covers %s", page)
	}
}

func TestCoverFiletypeReadsTheSanitizedFilename(t *testing.T) {
	for _, tc := range []struct{ filename, contentType, want string }{
		{"cover.jpg?alt=media&token=1c45", "image/jpeg", "jpg-alt=media&token=1c45"},
		{"cover.png?verify=17%3D", "image/png", "png-verify=17-3D"},
		{"img.c?d/e", "image/png", "c-d-e"},
		{" cover.jpeg \n", "image/jpeg", "jpeg"},
		{"cover", "image/webp", "webp"},
		{"a.b\\c\u202Ed", "image/png", "b-c-d"},
	} {
		if got := (&cover{filename: tc.filename, contentType: tc.contentType}).filetype(); got != tc.want {
			t.Errorf("filetype of %q = %v, want %q", tc.filename, got, tc.want)
		}
	}
}
