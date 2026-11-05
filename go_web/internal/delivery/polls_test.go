package delivery

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

func (e *env) alive(r *Redirect) []ProductFile {
	e.t.Helper()
	files, err := AliveProductFiles(context.Background(), e.db, r, e.ids)
	if err != nil {
		e.t.Fatal(err)
	}
	return files
}

// jsonFor fills {100}, {101}... with the external ids of base+100, base+101...
func (e *env) jsonFor(template string) string {
	for i := int64(100); i < 120; i++ {
		template = strings.ReplaceAll(template, fmt.Sprintf("{%d}", i), e.ids.Encrypt(base+i))
	}
	return template
}

func TestAudioDurationsAreContentLengthsOfTheAudioFilegroup(t *testing.T) {
	e := newEnv(t)
	product, purchase := base+1, base+20
	e.insertProduct(product, 0)
	e.purchase(purchase, product)
	for i, columns := range []map[string]any{
		{"filetype": "mp3", "filegroup": "audio", "duration": 120, "pagelength": 4},
		{"filetype": "mp3", "filegroup": "audio"},
		// where(filegroup: "audio") is the collation's match; listenable? is Ruby's ==.
		{"filetype": "mp3", "filegroup": "Audio", "duration": 60, "pagelength": 7},
		{"filetype": "epub", "filegroup": "AUDIO ", "pagelength": 9},
		{"filetype": "mp3", "filegroup": "áudio", "duration": 60, "pagelength": 11},
		{"filetype": "mp3", "filegroup": "audiobook", "duration": 60},
		{"filetype": "mp4", "filegroup": "video", "duration": 30},
		{"filetype": "pdf", "filegroup": "document", "pagelength": 3},
		{"filetype": "mp3", "filegroup": "audio", "duration": 5, "deleted_at": stamp},
		{"filetype": "mp3", "filegroup": nil, "duration": 5},
	} {
		columns["link_id"], columns["position"] = product, i
		e.file(base+100+int64(i), columns)
	}
	got := rails.EncodeJSON(AudioDurations(e.alive(&Redirect{PurchaseID: ptr(purchase)}), e.ids))
	if want := e.jsonFor(`{"{100}":120,"{101}":null,"{102}":7,"{103}":100,"{104}":11}`); got != want {
		t.Fatalf("audio_durations = %s\nwant %s", got, want)
	}

	// The habtm join's repeated row is one key, where the hash first saw it.
	files := []ProductFile{{ID: base + 101, Filegroup: "audio", audio: true}, {ID: base + 100, Filegroup: "audio", Duration: ptr(3), audio: true},
		{ID: base + 101, Filegroup: "audio", audio: true}}
	if got, want := rails.EncodeJSON(AudioDurations(files, e.ids)), e.jsonFor(`{"{101}":null,"{100}":3}`); got != want {
		t.Fatalf("audio_durations = %s\nwant %s", got, want)
	}
	if got := rails.EncodeJSON(AudioDurations(nil, e.ids)); got != "{}" {
		t.Fatalf("audio_durations without files = %s", got)
	}
}

func TestLatestMediaLocationsForTheDownloadPage(t *testing.T) {
	e := newEnv(t)
	product, purchase, other := base+1, base+20, base+21
	e.insertProduct(product, 0)
	e.purchase(purchase, product)
	e.purchase(other, product)
	const earlier, latest = "2026-02-03 04:05:06", "2026-02-03 05:06:07"
	type location struct {
		unit       any
		location   int64
		consumedAt any
	}
	fileLocations := []struct {
		columns   map[string]any
		locations []location
	}{
		{map[string]any{"filetype": "mp3", "filegroup": "audio"}, []location{{"seconds", 10, earlier}, {"seconds", 30, latest}}},
		{map[string]any{"filetype": "pdf", "filegroup": "document", "pagelength": 20}, []location{{"page_number", 4, latest}}},
		// An EPUB's page numbers become a percentage of its pagelength, floored and kept under 100.
		{map[string]any{"filetype": "epub", "filegroup": "document", "pagelength": 7}, []location{{"page_number", 3, latest}}},
		{map[string]any{"filetype": "epub", "filegroup": "document", "pagelength": 10}, []location{{"page_number", 12, latest}}},
		{map[string]any{"filetype": "epub", "filegroup": "document", "pagelength": 7}, []location{{"page_number", 7, latest}}},
		{map[string]any{"filetype": "epub", "filegroup": "document", "pagelength": 7}, []location{{"page_number", -1, latest}}},
		{map[string]any{"filetype": "epub", "filegroup": "document", "pagelength": nil}, []location{{"page_number", 2, latest}}},
		{map[string]any{"filetype": "epub", "filegroup": "document", "pagelength": 0}, []location{{"page_number", 2, latest}}},
		{map[string]any{"filetype": "epub", "filegroup": "document", "pagelength": 8}, []location{{"percentage", 55, latest}}},
		// Units the file can't use.
		{map[string]any{"filetype": "pdf", "filegroup": "document"}, []location{{"seconds", 4, latest}}},
		{map[string]any{"filetype": "png", "filegroup": "image"}, []location{{"page_number", 1, latest}}},
		{map[string]any{"filetype": "mp3", "filegroup": "Audio"}, []location{{"seconds", 1, latest}}},
		{map[string]any{"filetype": "mp3", "filegroup": "audio"}, []location{{nil, 1, latest}}},
		// No row, and a row MAX(consumed_at) can never join.
		{map[string]any{"filetype": "mp4", "filegroup": "video"}, nil},
		{map[string]any{"filetype": "mp4", "filegroup": "video"}, []location{{"seconds", 1, nil}}},
		// Rows tied at the latest time: index_by keeps the last MySQL returns.
		{map[string]any{"filetype": "mp4", "filegroup": "video"}, []location{{"seconds", 7, latest}, {"seconds", 9, latest}, {"seconds", 1, earlier}}},
	}
	locationID := base + 500
	for i, f := range fileLocations {
		id := base + 100 + int64(i)
		f.columns["link_id"], f.columns["position"] = product, i
		e.file(id, f.columns)
		for _, l := range f.locations {
			locationID++
			e.insert("media_locations", locationID, map[string]any{"product_file_id": id, "url_redirect_id": base, "purchase_id": purchase,
				"product_id": product, "unit": l.unit, "location": l.location, "consumed_at": l.consumedAt, "epub_cfi": "epubcfi(/6/4!/4/2)",
				"created_at": stamp, "updated_at": stamp})
		}
	}
	// Another purchase's progress is not this one's.
	e.insert("media_locations", base+600, map[string]any{"product_file_id": base + 113, "url_redirect_id": base, "purchase_id": other,
		"product_id": product, "unit": "seconds", "location": 5, "consumed_at": latest, "created_at": stamp, "updated_at": stamp})

	files := e.alive(&Redirect{PurchaseID: ptr(purchase)})
	got, err := LatestMediaLocations(context.Background(), e.db, ptr(purchase), false, files, e.ids)
	if err != nil {
		t.Fatal(err)
	}
	at := `"timestamp":"2026-02-03T05:06:07Z"`
	want := e.jsonFor(`{"{100}":{"location":30,"unit":"seconds",` + at + `},` +
		`"{101}":{"location":4,"unit":"page_number",` + at + `},` +
		`"{102}":{"location":42,"unit":"percentage",` + at + `},` +
		`"{103}":{"location":99,"unit":"percentage",` + at + `},` +
		`"{104}":{"location":99,"unit":"percentage",` + at + `},` +
		`"{105}":{"location":0,"unit":"percentage",` + at + `},` +
		`"{106}":null,"{107}":null,` +
		`"{108}":{"location":55,"unit":"percentage",` + at + `},` +
		`"{109}":null,"{110}":null,"{111}":null,"{112}":null,"{113}":null,"{114}":null,` +
		`"{115}":{"location":9,"unit":"seconds",` + at + `}}`)
	if body := rails.EncodeJSON(got); body != want {
		t.Fatalf("latest_media_locations = %s\nwant %s", body, want)
	}

	for _, tc := range []struct {
		purchaseID     *int64
		hasInstallment bool
	}{{nil, false}, {ptr(purchase), true}} {
		got, err := LatestMediaLocations(context.Background(), e.db, tc.purchaseID, tc.hasInstallment, files, e.ids)
		if err != nil || rails.EncodeJSON(got) != "{}" {
			t.Fatalf("latest_media_locations(%v, %v) = %v, %v; want {}", tc.purchaseID, tc.hasInstallment, got, err)
		}
	}
}
