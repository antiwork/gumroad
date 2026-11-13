package delivery

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
	"github.com/antiwork/gumroad/go_web/internal/storage"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

const (
	pageOwner    = base + 8_001
	pageProduct  = base + 8_101
	pagePurchase = base + 8_201
	pageRedirect = base + 8_301
	pageFolder   = base + 8_401
	pageFile     = base + 8_501 // and up
)

var pageConfig = ContentConfig{S3BaseURL: "https://s3.amazonaws.com/gumroad/", AssetHost: "https://assets.gumroad.com"}

// newPageEnv is a product of pageOwner's with a purchase and its redirect.
func newPageEnv(t *testing.T) (*env, *Redirect) {
	e := newEnv(t)
	testdb.User(t, e.db, pageOwner, map[string]any{"external_id": "8001"})
	e.insert("links", pageProduct, map[string]any{"name": "Guide", "user_id": pageOwner, "created_at": stamp, "updated_at": stamp})
	e.purchase(pagePurchase, pageProduct)
	return e, &Redirect{ID: pageRedirect, PurchaseID: ptr(pagePurchase)}
}

func (e *env) items(r *Redirect, c ContentRedirect) ([]any, error) {
	cfg := pageConfig
	cfg.IDs = e.ids
	return NewPage(context.Background(), e.db, r, e.ids).ContentItems(c, cfg)
}

func TestContentItemsMapFilesAndFolders(t *testing.T) {
	e, r := newPageEnv(t)
	e.insert("product_folders", pageFolder, map[string]any{"product_id": pageProduct, "name": "Extras", "position": 0, "created_at": stamp, "updated_at": stamp})
	guid := strings.Repeat("a", 32)
	e.file(pageFile, map[string]any{"link_id": pageProduct, "position": 0, "size": 2048, "pagelength": 10,
		"url": "https://s3.amazonaws.com/gumroad/attachments/" + guid + "/original/My Guide.pdf"})
	e.file(pageFile+1, map[string]any{"link_id": pageProduct, "position": 1, "filetype": "mp3", "filegroup": "audio", "duration": 61, "folder_id": pageFolder})
	e.file(pageFile+2, map[string]any{"link_id": pageProduct, "position": 2, "filetype": "link", "filegroup": "url", "url": "https://example.com/x"})

	items, err := e.items(r, ContentRedirect{Token: "tok", ReferencedProductID: ptr(pageProduct)})
	if err != nil {
		t.Fatal(err)
	}
	got := rails.EncodeJSON(items)
	pdf := e.ids.Encrypt(pageFile)
	for _, want := range []string{
		// The folder first, holding its file; then the files outside folders, in position order.
		`[{"type":"folder","id":"` + e.ids.Encrypt(pageFolder) + `","name":"Extras","children":[{"type":"file","file_name":null,`,
		`"extension":"MP3"`, `"duration":61`, `"content_length":61`,
		`{"type":"file","file_name":"My Guide","description":null,"extension":"PDF","web_build":null,"file_size":2048,"pagelength":10`,
		`"download_url":"/r/tok/product_files?product_file_ids%5B%5D=` + rails.CGIEscape(pdf) + `"`,
		`"kindle_data":{"email":null,"icon_url":"https://assets.gumroad.com/images/white-15.png"}`,
		`"read_url":"/read/tok/` + web.EscapeSegment(pdf) + `"`,
		`"file_name":"https://example.com/x","description":null,"extension":"URL"`,
		`"download_url":null,"archivable":false`, `"external_link_url":"https://example.com/x"`,
	} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %s in\n%s", want, got)
		}
	}
	if strings.Index(got, `"My Guide"`) > strings.Index(got, `"https://example.com/x"`) {
		t.Error("the root files are out of position order")
	}
}

func TestContentItemsHonorDownloadGrants(t *testing.T) {
	e, r := newPageEnv(t)
	e.file(pageFile, map[string]any{"link_id": pageProduct, "position": 0, "flags": FileStreamOnly})
	download := func() any {
		items, err := e.items(r, ContentRedirect{Token: "tok"})
		if err != nil {
			t.Fatal(err)
		}
		return items[0].(*rails.RHash).Get("download_url")
	}
	// A stream-only PDF has no download, unless this redirect was granted one.
	if got := download(); got != nil {
		t.Errorf("stream-only file downloadable: %v", got)
	}
	e.insert("product_file_download_grants", base+8_601, map[string]any{"url_redirect_id": pageRedirect, "product_file_id": pageFile,
		"created_at": stamp, "updated_at": stamp})
	if got := download(); got == nil {
		t.Error("a granted file has no download")
	}
}

func TestContentItemsLeaveToRailsWhatTheyDoNotMap(t *testing.T) {
	cases := map[string]func(e *env){
		"subtitles": func(e *env) {
			e.insert("subtitle_files", base+8_701, map[string]any{"product_file_id": pageFile, "created_at": stamp, "updated_at": stamp})
		},
		"stamped PDF": func(e *env) { e.exec("UPDATE product_files SET flags = ? WHERE id = ?", filePDFStampEnabled, pageFile) },
		"non-ASCII type": func(e *env) {
			e.exec("UPDATE product_files SET filetype = 'straße', url = NULL WHERE id = ?", pageFile)
		},
	}
	for name, setup := range cases {
		t.Run(name, func(t *testing.T) {
			e, r := newPageEnv(t)
			e.file(pageFile, map[string]any{"link_id": pageProduct, "position": 0})
			setup(e)
			if _, err := e.items(r, ContentRedirect{Token: "tok"}); !errors.Is(err, ErrUnported) {
				t.Errorf("got %v", err)
			}
		})
	}
}

// fakeCache is Rails.cache with fixed entries.
type fakeCache map[string]any

func (c fakeCache) Read(_ context.Context, key string) (any, bool, error) {
	v, ok := c[key]
	return v, ok, nil
}

func TestContentItemsThumbnails(t *testing.T) {
	const attachment, blob, variantRecord, variantImage, variantBlob = base + 8_702, base + 8_703, base + 8_704, base + 8_705, base + 8_706
	cacheKey := "attachment_product_file_thumbnail_" + strconv.FormatInt(attachment, 10) + "_variant_url"
	thumbnailURL := func(t *testing.T, filetype, filegroup, contentType string, cache fakeCache, variant bool) (any, error) {
		e, r := newPageEnv(t)
		e.file(pageFile, map[string]any{"link_id": pageProduct, "position": 0, "filetype": filetype, "filegroup": filegroup})
		e.insert("active_storage_blobs", blob, map[string]any{"key": "gowebthumb", "filename": "t.png", "content_type": contentType,
			"byte_size": 1, "service_name": "amazon", "created_at": stamp})
		e.insert("active_storage_attachments", attachment, map[string]any{"name": "thumbnail", "record_type": "ProductFile",
			"record_id": pageFile, "blob_id": blob, "created_at": stamp})
		if variant {
			e.insert("active_storage_variant_records", variantRecord, map[string]any{"blob_id": blob,
				"variation_digest": storage.VariantDigest("t.png", contentType, 1280, 720)})
			e.insert("active_storage_blobs", variantBlob, map[string]any{"key": "gowebthumbvariant", "filename": "t.png", "byte_size": 1,
				"service_name": "amazon", "created_at": stamp})
			e.insert("active_storage_attachments", variantImage, map[string]any{"name": "image", "record_type": "ActiveStorage::VariantRecord",
				"record_id": variantRecord, "blob_id": variantBlob, "created_at": stamp})
		}
		cfg := pageConfig
		cfg.IDs, cfg.PublicStorage, cfg.Cache = e.ids, "https://gumroad-public-storage.s3.amazonaws.com/", cache
		cfg.CDNMap = [][2]string{{"https://gumroad-public-storage.s3.amazonaws.com/", "https://public-files.gumroad.com/"}}
		items, err := NewPage(context.Background(), e.db, r, e.ids).ContentItems(ContentRedirect{Token: "tok"}, cfg)
		if err != nil {
			return nil, err
		}
		return items[0].(*rails.RHash).Get("thumbnail_url"), nil
	}
	for name, c := range map[string]struct {
		filetype, filegroup, contentType string
		cache                            fakeCache
		variant                          bool
		want                             any
	}{
		// The editor uploads an image's thumbnail already downscaled.
		"image":             {"png", "image", "image/png", nil, false, "https://public-files.gumroad.com/gowebthumb"},
		"document":          {"pdf", "document", "image/png", nil, false, nil},
		"video, cached":     {"mp4", "video", "image/png", fakeCache{cacheKey: "https://gumroad-public-storage.s3.amazonaws.com/cached"}, false, "https://public-files.gumroad.com/cached"},
		"video, variant":    {"mp4", "video", "image/png", fakeCache{}, true, "https://public-files.gumroad.com/gowebthumbvariant"},
		"video, no variant": {"mp4", "video", "image/webp", fakeCache{}, false, "https://public-files.gumroad.com/gowebthumb"},
	} {
		t.Run(name, func(t *testing.T) {
			got, err := thumbnailURL(t, c.filetype, c.filegroup, c.contentType, c.cache, c.variant)
			if err != nil || got != c.want {
				t.Errorf("got %v, %v; want %v", got, err, c.want)
			}
		})
	}
	// A variant still to be made is resized in Rails' request.
	if _, err := thumbnailURL(t, "mp4", "video", "image/png", fakeCache{}, false); !errors.Is(err, ErrUnported) {
		t.Errorf("unprocessed variant: %v", err)
	}
}

func TestRichContentPagesInPositionOrder(t *testing.T) {
	e, r := newPageEnv(t)
	e.insert("rich_contents", base+8_801, map[string]any{"entity_type": "Link", "entity_id": pageProduct, "title": "Second", "position": 1,
		"description": textPage, "created_at": stamp, "updated_at": stamp})
	e.insert("rich_contents", base+8_802, map[string]any{"entity_type": "Link", "entity_id": pageProduct, "title": "First", "position": 0,
		"description": `[{"type":"posts"}]`, "created_at": stamp, "updated_at": stamp})
	pages, err := NewPage(context.Background(), e.db, r, e.ids).RichContentPages()
	if err != nil {
		t.Fatal(err)
	}
	got := rails.EncodeJSON(pages.JSON)
	if !strings.HasPrefix(got, `[{"id":"`+e.ids.Encrypt(base+8_802)+`","page_id":"`+e.ids.Encrypt(base+8_802)+`","title":"First","variant_id":null,`+
		`"description":{"type":"doc","content":[{"type":"posts"}]},"updated_at":"2026-01-01T00:00:00Z"}`) || !pages.MayHavePosts {
		t.Errorf("pages %s, posts %v", got, pages.MayHavePosts)
	}

	// has_posts? raises on a description that isn't a list.
	e.exec("UPDATE rich_contents SET description = 'null' WHERE id = ?", base+8_801)
	if _, err := NewPage(context.Background(), e.db, r, e.ids).RichContentPages(); !errors.Is(err, ErrUnported) {
		t.Errorf("a null description: %v", err)
	}
}

func TestRichContentPagesOfAPurchasedVariant(t *testing.T) {
	e, r := newPageEnv(t)
	category, variant := base+8_901, base+8_911
	e.category(category, pageProduct)
	e.variant(variant, category, nil)
	e.file(pageFile, map[string]any{"link_id": pageProduct, "position": 0})
	e.attach(variant, pageFile)
	e.buys(pagePurchase, variant)
	e.insert("rich_contents", base+8_803, map[string]any{"entity_type": "BaseVariant", "entity_id": variant, "title": "Deluxe", "position": 0,
		"description": textPage, "created_at": stamp, "updated_at": stamp})
	e.insert("rich_contents", base+8_804, map[string]any{"entity_type": "Link", "entity_id": pageProduct, "title": "Shared", "position": 0,
		"description": textPage, "created_at": stamp, "updated_at": stamp})
	pages, err := NewPage(context.Background(), e.db, r, e.ids).RichContentPages()
	if err != nil {
		t.Fatal(err)
	}
	if got := rails.EncodeJSON(pages.JSON); !strings.HasPrefix(got, `[{"id":"`+e.ids.Encrypt(base+8_803)+`","page_id":"`+e.ids.Encrypt(base+8_803)+
		`","title":"Deluxe","variant_id":"`+e.ids.Encrypt(variant)+`",`) {
		t.Errorf("variant pages %s", got)
	}

	// While the product shares one set of pages, the purchase gets the product's.
	e.exec("UPDATE links SET flags = flags | ? WHERE id = ?", productHasSameRichContentForAllVariants, pageProduct)
	pages, err = NewPage(context.Background(), e.db, r, e.ids).RichContentPages()
	if err != nil {
		t.Fatal(err)
	}
	if got := rails.EncodeJSON(pages.JSON); !strings.HasPrefix(got, `[{"id":"`+e.ids.Encrypt(base+8_804)+`","page_id":"`+e.ids.Encrypt(base+8_804)+
		`","title":"Shared","variant_id":null,`) {
		t.Errorf("shared pages %s", got)
	}
}

func TestOwnerIsTheProductAndItsUser(t *testing.T) {
	e, r := newPageEnv(t)
	o, err := NewPage(context.Background(), e.db, r, e.ids).Owner()
	if err != nil {
		t.Fatal(err)
	}
	if o.VariantID != nil || o.Name.String != "Guide" || o.ReferencedName.String != "Guide" || *o.SellerID != pageOwner || *o.ReferencedProductID != pageProduct {
		t.Errorf("owner %+v", o)
	}
}
