package products

import (
	"database/sql"
	"fmt"
	"net/http"
	"strings"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
)

// set_affiliate_cookie sets the found affiliate's cookie after the browser's guid, on the page
// and on a redirect alike: a deleted direct affiliate's cookie goes to the newest alive account
// of its user with the seller, and a Collaborator, without a cookie lifetime, raises in Rails.
func TestTheAffiliateCookie(t *testing.T) {
	const (
		direct, global, collaborator = int64(1_799_201), int64(1_799_202), int64(1_799_203)
		older, newer                 = int64(1_799_204), int64(1_799_205)
	)
	insert := func(t *testing.T, conn *sql.DB, id int64, typ string, sellerID any, deleted bool) {
		row := map[string]any{"id": id, "type": typ, "seller_id": sellerID, "affiliate_user_id": buyerID,
			"created_at": testNow, "updated_at": testNow}
		if deleted {
			row["deleted_at"] = testNow
		}
		testdb.Insert(t, conn, "affiliates", row)
	}
	for _, c := range []struct {
		name, query, reason string
		setup               func(t *testing.T, e *testEnv, conn *sql.DB)
		// id is the affiliate the query names, direct by default; cookie is the one whose cookie
		// is set, for days, 0 for none.
		id, cookie int64
		days       int
		redirect   bool
	}{
		{name: "a direct affiliate", query: "?a=%d", cookie: direct, days: 30,
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				insert(t, conn, direct, "DirectAffiliate", sellerID, false)
			}},
		{name: "a global affiliate through affiliate_id", query: "?affiliate_id=%d", id: global, cookie: global, days: 7,
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { insert(t, conn, global, "GlobalAffiliate", nil, false) }},
		{name: "a blank affiliate_id, then a", query: "?affiliate_id=+&a=%d", cookie: direct, days: 30,
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				insert(t, conn, direct, "DirectAffiliate", sellerID, false)
			}},
		{name: "an array", query: "?a[]=%d", cookie: direct, days: 30,
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				insert(t, conn, direct, "DirectAffiliate", sellerID, false)
			}},
		{name: "on the redirect", query: "?a=%d", cookie: direct, days: 30, redirect: true,
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				insert(t, conn, direct, "DirectAffiliate", sellerID, false)
			}},
		{name: "a deleted direct affiliate's newest alive account", query: "?a=%d", cookie: newer, days: 30,
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				insert(t, conn, direct, "DirectAffiliate", sellerID, true)
				insert(t, conn, older, "DirectAffiliate", sellerID, false)
				insert(t, conn, newer, "DirectAffiliate", sellerID, false)
				// Newer still, but deleted, for another seller, not direct, or another user's.
				insert(t, conn, 1_799_206, "DirectAffiliate", sellerID, true)
				insert(t, conn, 1_799_207, "DirectAffiliate", buyerID, false)
				insert(t, conn, 1_799_208, "GlobalAffiliate", sellerID, false)
				testdb.Insert(t, conn, "affiliates", map[string]any{"id": int64(1_799_209), "type": "DirectAffiliate", "seller_id": sellerID,
					"affiliate_user_id": sellerID, "created_at": testNow, "updated_at": testNow})
			}},
		{name: "a deleted direct affiliate whose seller is gone", query: "?a=%d", reason: "affiliate account",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				insert(t, conn, direct, "DirectAffiliate", int64(1_799_299), true)
			}},
		{name: "a deleted base Affiliate", query: "?a=%d", reason: "affiliate type",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { insert(t, conn, direct, "Affiliate", sellerID, true) }},
		{name: "a negative number, which decrypts as its absolute value", query: "?a=-%d", cookie: direct, days: 30,
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				insert(t, conn, direct, "DirectAffiliate", sellerID, false)
			}},
		{name: "a 0d prefix", query: "?a=0d%d", cookie: direct, days: 30,
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				insert(t, conn, direct, "DirectAffiliate", sellerID, false)
			}},
		{name: "a deleted direct affiliate with no other account", query: "?a=%d",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				insert(t, conn, direct, "DirectAffiliate", sellerID, true)
			}},
		{name: "a deleted global affiliate", query: "?a=%d",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { insert(t, conn, direct, "GlobalAffiliate", nil, true) }},
		{name: "no affiliate", query: "?a=%d"},
		{name: "not a number", query: "?a=x"},
		{name: "a hash", query: "?a[x]=1"},
		{name: "a collaborator", query: "?a=%d", reason: "affiliate type", id: collaborator,
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				insert(t, conn, collaborator, "Collaborator", sellerID, false)
			}},
		{name: "a Bignum", query: "?a=99999999999999999999", reason: "affiliate id"},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			conn := testdb.Open(t)
			addBuyer(t, conn, nil)
			if c.setup != nil {
				c.setup(t, e, conn)
			}
			query := c.query
			if strings.Contains(query, "%d") {
				id := c.id
				if id == 0 {
					id = direct
				}
				numeric, _ := e.ids.EncryptNumeric(id)
				query = fmt.Sprintf(query, numeric)
			}
			target := "/l/guide" + query
			if c.redirect {
				target = "/l/gowebp1" + query
			}
			var header http.Header
			if c.redirect {
				w := e.get(host, target, nil)
				if w.Code != http.StatusMovedPermanently || e.railsHit != nil {
					t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
				}
				header = w.Header()
			} else if _, header = e.renderAt(t, target, nil, c.reason); c.reason != "" {
				return
			}
			cookies := header.Values("Set-Cookie")
			var affiliate []string
			for i, line := range cookies {
				if strings.HasPrefix(line, affiliateCookiePrefix) {
					affiliate = append(affiliate, line)
					if i == 0 || !strings.HasPrefix(cookies[i-1], "_gumroad_guid=") {
						t.Errorf("cookie order %v", cookies)
					}
				}
			}
			if c.cookie == 0 {
				if len(affiliate) != 0 {
					t.Errorf("cookies %v", affiliate)
				}
				return
			}
			want := fmt.Sprintf("%s%s=%d; domain=gumroad.com; path=/; expires=%s; httponly; samesite=lax",
				affiliateCookiePrefix, strings.TrimRight(e.ids.Encrypt(c.cookie), "="), testNow.Unix(),
				testNow.UTC().AddDate(0, 0, c.days).Format(http.TimeFormat))
			if len(affiliate) != 1 || !strings.HasPrefix(affiliate[0], want) {
				t.Errorf("cookies %v, want %s", affiliate, want)
			}
		})
	}
}
