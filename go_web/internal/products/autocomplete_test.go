package products

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/elastic"
	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
)

// autocompleteHeaders is Discover's search box reloading autocomplete_results for a browser.
func autocompleteHeaders(guid string) map[string]string {
	return map[string]string{"X-Inertia": "true", "X-Inertia-Partial-Component": discoverComponent,
		"X-Inertia-Partial-Data": autocompleteData, "Cookie": "_gumroad_guid=" + guid}
}

// Discover's search box reloads only autocomplete_results: the recent searches, then products
// that match the query, the browser's recent views, or Discover's featured ones, with the meta
// tags the before_actions set.
func TestTheDiscoverAutocomplete(t *testing.T) {
	const missing, viewedGUID = int64(1_797_999), "guid-viewed"
	type searched struct {
		index string
		body  map[string]any
	}
	setup := func(t *testing.T) (*testEnv, *sql.DB, *[]searched) {
		e := newTestEnv(t)
		conn := testdb.Open(t)
		var searches []searched
		server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			raw, _ := io.ReadAll(r.Body)
			var body map[string]any
			if err := json.Unmarshal(raw, &body); err != nil {
				t.Errorf("search body %s", raw)
			}
			index := strings.Split(strings.TrimPrefix(r.URL.Path, "/"), "/")[0]
			searches = append(searches, searched{index, body})
			if index == "product_page_views" {
				hits := `[]`
				if strings.Contains(string(raw), viewedGUID) {
					hits = fmt.Sprintf(`[{"_source":{"product_id":%d}},{"_source":{"product_id":%d}}]`, productID, productID)
				}
				io.WriteString(w, `{"hits":{"hits":`+hits+`}}`)
				return
			}
			// A product the database no longer has drops out.
			io.WriteString(w, fmt.Sprintf(`{"hits":{"hits":[{"_id":"%d"},{"_id":"%d"}]}}`, missing, productID))
		}))
		t.Cleanup(server.Close)
		client, err := elastic.NewWithClient(server.URL, server.Client())
		if err != nil {
			t.Fatal(err)
		}
		e.config.Page.Search = client
		return e, conn, &searches
	}
	suggest := func(t *testing.T, conn *sql.DB, id int64, guid string, query any, deleted bool) {
		testdb.Insert(t, conn, "discover_searches", map[string]any{"id": id, "browser_guid": guid, "query": query,
			"created_at": testNow, "updated_at": testNow})
		row := map[string]any{"id": id, "discover_search_id": id, "created_at": testNow.Add(-time.Duration(id%100) * time.Minute), "updated_at": testNow}
		if deleted {
			row["deleted_at"] = testNow
		}
		testdb.Insert(t, conn, "discover_search_suggestions", row)
	}
	reload := func(t *testing.T, e *testEnv, target, guid string) map[string]any {
		t.Helper()
		w := e.get(host, target, autocompleteHeaders(guid))
		if w.Code != http.StatusOK || e.railsHit != nil || w.Header().Get("X-Inertia") != "true" {
			t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
		}
		var page map[string]any
		if err := json.Unmarshal(w.Body.Bytes(), &page); err != nil {
			t.Fatal(err)
		}
		if page["component"] != discoverComponent || page["url"] != target {
			t.Errorf("page %v %v", page["component"], page["url"])
		}
		props := page["props"].(map[string]any)
		if errs, ok := props["errors"].(map[string]any); len(props) != 3 || props["_inertia_meta"] == nil || !ok || len(errs) != 0 {
			t.Errorf("props %v", props)
		}
		if csp := w.Header().Get("Content-Security-Policy"); csp == "" || strings.Contains(csp, "nonce-") {
			t.Errorf("CSP %q", csp)
		}
		// errors, the always prop, leads; the meta tags come last.
		if body := w.Body.String(); !strings.Contains(body, `"props":{"errors":{},"autocomplete_results":{`) {
			t.Errorf("props order in %.200s", body[strings.Index(body, `"props"`):])
		}
		return props[autocompleteData].(map[string]any)
	}
	guide := map[string]any{"name": "Guide <1>", "seller_name": "Seller", "thumbnail_url": nil}
	withURL := func(query string) map[string]any {
		out := map[string]any{"url": "https://" + host + "/l/guide?autocomplete=true&layout=discover" + query + "&recommended_by=search"}
		for k, v := range guide {
			out[k] = v
		}
		return out
	}

	t.Run("a typed query", func(t *testing.T) {
		e, conn, searches := setup(t)
		// Newest first: the deleted suggestion and another browser's drop out.
		suggest(t, conn, 1_797_001, "guid-a", "Pen Set", false)
		suggest(t, conn, 1_797_002, "guid-a", "markers", false)
		suggest(t, conn, 1_797_003, "guid-a", "pens", false)
		suggest(t, conn, 1_797_004, "guid-a", "pen pals", true)
		suggest(t, conn, 1_797_005, "guid-b", "pen", false)
		suggest(t, conn, 1_797_006, "guid-a", "pens", false)
		got := reload(t, e, "/l/guide?layout=discover&query=PEN", "guid-a")
		want := map[string]any{"recent_searches": []any{"Pen Set", "pens"}, "products": []any{withURL("&query=pen")}}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("got %v\nwant %v", got, want)
		}
		if len(*searches) != 1 || (*searches)[0].index != "products" {
			t.Fatalf("searches %v", *searches)
		}
		must := (*searches)[0].body["query"].(map[string]any)["bool"].(map[string]any)["must"].([]any)
		if q := must[0].(map[string]any)["simple_query_string"].(map[string]any)["query"]; q != "pen" {
			t.Errorf("searched %v", q)
		}
	})
	// create_discover_search! records a typed query's suggestion before the presenter reads them.
	t.Run("a typed query from a search click", func(t *testing.T) {
		e, conn, _ := setup(t)
		e.redis.HSet("store_discover_searches", "boolean", "true")
		t.Cleanup(func() {
			conn.Exec("DELETE discover_search_suggestions FROM discover_search_suggestions INNER JOIN discover_searches" +
				" ON discover_searches.id = discover_search_suggestions.discover_search_id WHERE discover_searches.clicked_resource_id = " +
				strconv.FormatInt(productID, 10))
			conn.Exec("DELETE FROM discover_searches WHERE clicked_resource_id = ?", productID)
		})
		suggest(t, conn, 1_797_031, "guid-c", "pen", false)
		suggest(t, conn, 1_797_032, "guid-c", "pens", false)
		got := reload(t, e, "/l/guide?layout=discover&recommended_by=search&query=Pen+Cases", "guid-c")
		if want := []any{"Pen Cases", "pen"}; !reflect.DeepEqual(got["recent_searches"], want) {
			t.Errorf("recent searches %v, want %v", got["recent_searches"], want)
		}
	})
	t.Run("a blank query after recent views", func(t *testing.T) {
		e, conn, searches := setup(t)
		suggest(t, conn, 1_797_011, viewedGUID, "pens", false)
		suggest(t, conn, 1_797_012, viewedGUID, "pens", false)
		got := reload(t, e, "/l/guide?layout=discover&query=", viewedGUID)
		want := map[string]any{"recent_searches": []any{"pens"}, "products": []any{withURL("")}, "viewed": true}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("got %v\nwant %v", got, want)
		}
		if len(*searches) != 2 || (*searches)[1].body["size"] != float64(catalogPageSize) {
			t.Fatalf("searches %v", *searches)
		}
		must := (*searches)[1].body["query"].(map[string]any)["bool"].(map[string]any)["must"].([]any)
		if ids := must[2].(map[string]any)["terms"].(map[string]any)["_id"]; !reflect.DeepEqual(ids, []any{float64(productID), float64(productID)}) {
			t.Errorf("ids %v", ids)
		}
	})
	t.Run("a blank query without views", func(t *testing.T) {
		e, _, searches := setup(t)
		got := reload(t, e, "/l/guide?layout=discover", "guid-new")
		want := map[string]any{"recent_searches": []any{}, "products": []any{withURL("")}, "viewed": false}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("got %v\nwant %v", got, want)
		}
		if len(*searches) != 2 || (*searches)[1].body["size"] != float64(autocompleteProductCount) {
			t.Fatalf("searches %v", *searches)
		}
	})
	// The before_actions set the same tags whatever the response renders.
	t.Run("the meta tags", func(t *testing.T) {
		e, _, _ := setup(t)
		w := e.get(host, "/l/guide?layout=discover", autocompleteHeaders("guid-a"))
		plain := e.get(host, "/l/guide", map[string]string{"X-Inertia": "true", "Cookie": "_gumroad_guid=guid-a"})
		meta := func(body []byte) any {
			var page struct {
				Props struct {
					Meta []map[string]any `json:"_inertia_meta"`
				} `json:"props"`
			}
			if err := json.Unmarshal(body, &page); err != nil {
				t.Fatal(err)
			}
			for _, tag := range page.Props.Meta {
				if tag["headKey"] == "meta-name-csrf-token" {
					tag["content"] = ""
				}
			}
			return page.Props.Meta
		}
		if got, want := meta(w.Body.Bytes()), meta(plain.Body.Bytes()); !reflect.DeepEqual(got, want) {
			t.Errorf("meta %v\nwant %v", got, want)
		}
	})
	t.Run("what Rails answers", func(t *testing.T) {
		for _, c := range []struct {
			name, target, reason string
			headers              map[string]string
			setup                func(t *testing.T, conn *sql.DB)
		}{
			{name: "another layout", target: "/l/guide?query=pen", reason: "inertia partial reload"},
			{name: "another component's reload", target: "/l/guide?layout=discover", reason: "inertia header X-Inertia-Partial-Component",
				headers: map[string]string{"X-Inertia-Partial-Component": productComponent}},
			{name: "more data", target: "/l/guide?layout=discover", reason: "inertia header X-Inertia-Partial-Data",
				headers: map[string]string{"X-Inertia-Partial-Data": autocompleteData + ",products"}},
			{name: "a reset", target: "/l/guide?layout=discover", reason: "inertia header X-Inertia-Reset",
				headers: map[string]string{"X-Inertia-Reset": autocompleteData}},
			{name: "without X-Inertia", target: "/l/guide?layout=discover", reason: "inertia partial without X-Inertia",
				headers: map[string]string{"X-Inertia": ""}},
			{name: "a JSON format", target: "/l/guide.json?layout=discover", reason: "inertia partial reload"},
			{name: "a recent search without a query", target: "/l/guide?layout=discover&query=pen", reason: "recent search without a query",
				setup: func(t *testing.T, conn *sql.DB) { suggest(t, conn, 1_797_021, "guid-a", nil, false) }},
		} {
			t.Run(c.name, func(t *testing.T) {
				e, conn, _ := setup(t)
				if c.setup != nil {
					c.setup(t, conn)
				}
				headers := autocompleteHeaders("guid-a")
				for k, v := range c.headers {
					if v == "" {
						delete(headers, k)
					} else {
						headers[k] = v
					}
				}
				for k, v := range e.dryRun(host, c.target, testNow) {
					headers[k] = v
				}
				if w := e.get(host, c.target, headers); w.Code != http.StatusNoContent || w.Header().Get("X-Go-Web-Fallback") != c.reason {
					t.Errorf("%d %q, want %q", w.Code, w.Header().Get("X-Go-Web-Fallback"), c.reason)
				}
			})
		}
	})
}
