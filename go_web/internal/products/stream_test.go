package products

import (
	"html"
	"net/http"
	"strings"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/delivery"
	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
)

func TestStreamOnlyFiles(t *testing.T) {
	for _, c := range []struct {
		name                string
		filetype, filegroup string
		size                int64
		want                string
	}{
		{"a stream-only video", "mp4", "video", 2048, `"is_stream_only":true`},
		{"a stream-only PDF", "pdf", "document", 2048, `"is_stream_only":true`},
		// can_disable_downloads? is false for these, so the flag doesn't count.
		{"a flagged zip", "zip", "archive", 2048, `"is_stream_only":false`},
		{"a flagged EPUB past the reader's limit", "epub", "document", 32<<20 + 1, `"is_stream_only":false`},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			testdb.Insert(t, testdb.Open(t), "product_files", map[string]any{"id": int64(1_794_101), "link_id": productID,
				"filetype": c.filetype, "filegroup": c.filegroup, "size": c.size, "flags": delivery.FileStreamOnly,
				"url": "https://s3.amazonaws.com/gumroad/attachments/x/y/original/a." + c.filetype, "created_at": testNow, "updated_at": testNow})
			w := e.get(host, "/l/guide", nil)
			if w.Code != http.StatusOK {
				t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
			}
			if page := html.UnescapeString(dataPage.FindStringSubmatch(w.Body.String())[1]); !strings.Contains(page, c.want) {
				t.Errorf("want %s", c.want)
			}
		})
	}
}

func TestPublicFiles(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	for i, f := range []struct{ publicID, name, fileType, key string }{
		{"aaaaaaaaaaaaaaaa", "Intro", "mp3", "public/intro"},
		{"bbbbbbbbbbbbbbbb", "Outro", "", "public/outro"},
	} {
		id := int64(1_794_201 + i)
		row := map[string]any{"id": id, "resource_type": "Link", "resource_id": productID, "public_id": f.publicID,
			"display_name": f.name, "original_file_name": f.name + ".mp3", "created_at": testNow, "updated_at": testNow}
		if f.fileType != "" {
			row["file_type"] = f.fileType
		}
		testdb.Insert(t, conn, "public_files", row)
		testdb.Insert(t, conn, "active_storage_blobs", map[string]any{"id": id + 100, "key": f.key, "filename": f.name + ".mp3",
			"content_type": "audio/mpeg", "service_name": "amazon", "byte_size": 4096 + i, "created_at": testNow})
		testdb.Insert(t, conn, "active_storage_attachments", map[string]any{"id": id + 200, "name": "file", "record_type": "PublicFile",
			"record_id": id, "blob_id": id + 100, "created_at": testNow})
	}
	// A deleted one stays out.
	testdb.Insert(t, conn, "public_files", map[string]any{"id": int64(1_794_299), "resource_type": "Link", "resource_id": productID,
		"public_id": "cccccccccccccccc", "display_name": "Gone", "original_file_name": "gone.mp3", "deleted_at": testNow,
		"created_at": testNow, "updated_at": testNow})
	w := e.get(host, "/l/guide", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	want := `"public_files":[{"id":"aaaaaaaaaaaaaaaa","name":"Intro","extension":"MP3","file_size":4096,` +
		`"url":"https://public-files.gumroad.com/public/intro","status":{"type":"saved"}},` +
		`{"id":"bbbbbbbbbbbbbbbb","name":"Outro","extension":null,"file_size":4097,` +
		`"url":"https://public-files.gumroad.com/public/outro","status":{"type":"saved"}}]`
	if page := html.UnescapeString(dataPage.FindStringSubmatch(w.Body.String())[1]); !strings.Contains(page, want) {
		t.Errorf("want %s", want)
	}
}

func TestAPublicFileThisPortCannotReadGoesToRails(t *testing.T) {
	for name, setup := range map[string]func(t *testing.T, e *testEnv){
		"a non-ASCII file type": func(t *testing.T, e *testEnv) {
			conn := testdb.Open(t)
			conn.Exec("UPDATE public_files SET file_type = 'mpé' WHERE id = 1794301")
			testdb.Insert(t, conn, "active_storage_blobs", map[string]any{"id": int64(1_794_501), "key": "public/k", "filename": "a.mp3",
				"content_type": "audio/mpeg", "service_name": "amazon", "byte_size": 1, "created_at": testNow})
			testdb.Insert(t, conn, "active_storage_attachments", map[string]any{"id": int64(1_794_401), "name": "file",
				"record_type": "PublicFile", "record_id": int64(1_794_301), "blob_id": int64(1_794_501), "created_at": testNow})
		},
	} {
		t.Run(name, func(t *testing.T) {
			e := newTestEnv(t)
			testdb.Insert(t, testdb.Open(t), "public_files", map[string]any{"id": int64(1_794_301), "resource_type": "Link",
				"resource_id": productID, "public_id": "dddddddddddddddd", "display_name": "D", "original_file_name": "d.mp3",
				"file_type": "mp3", "created_at": testNow, "updated_at": testNow})
			setup(t, e)
			w := e.get(host, "/l/guide", e.dryRun(host, "/l/guide", testNow))
			if reason := w.Header().Get("X-Go-Web-Fallback"); w.Code != http.StatusNoContent || !strings.HasPrefix(reason, "public file") {
				t.Errorf("%d %q", w.Code, reason)
			}
		})
	}
}
