package products

import (
	"database/sql"
	"fmt"
	"html"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session"
	"github.com/antiwork/gumroad/go_web/internal/session/sessiontest"
	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
)

const buyerID = int64(1_796_001)

// signedIn is the session cookie Devise and the CSRF commit leave for a signed-in user.
func (e *testEnv) signedIn(userID int64, extra map[string]any) map[string]string {
	e.t.Helper()
	s := rails.NewRHash().
		Str("session_id", "0123456789abcdef0123456789abcdef").
		Str("warden.user.user.key", []any{[]any{userID}, "salt"}).
		Str("warden.user.user.session", rails.NewRHash().Str("last_sign_in_at", testNow.Unix())).
		Str("_csrf_token", session.GenerateCSRFToken())
	for k, v := range extra {
		s.Str(k, v)
	}
	cookie := sessiontest.Encrypt(e.t, testSecretKeyBase, "_gumroad_app_session", []byte(rails.EncodeJSON(s)), testNow.Add(time.Hour))
	return map[string]string{"Cookie": "_gumroad_app_session=" + url.QueryEscape(cookie)}
}

func addBuyer(t *testing.T, conn *sql.DB, extra map[string]any) {
	row := map[string]any{"username": "gowebbuyer", "external_id": "1796001", "name": "Buyer", "email": "buyer@example.com",
		"confirmed_at": testNow, "timezone": "Pacific Time (US & Canada)", "currency_type": "eur", "user_risk_state": "compliant"}
	for k, v := range extra {
		row[k] = v
	}
	testdb.User(t, conn, buyerID, row)
}

// A signed-in visitor on someone else's product: the shared props say who they are, and the
// page lists their wishlists and their currency.
func TestASignedInVisitor(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	addBuyer(t, conn, nil)
	testdb.Insert(t, conn, "wishlists", map[string]any{"id": int64(1_796_101), "user_id": buyerID, "name": "Gifts",
		"created_at": testNow, "updated_at": testNow})
	testdb.Insert(t, conn, "wishlists", map[string]any{"id": int64(1_796_102), "user_id": buyerID, "name": "Gone", "deleted_at": testNow,
		"created_at": testNow, "updated_at": testNow})
	testdb.Insert(t, conn, "wishlist_products", map[string]any{"id": int64(1_796_201), "wishlist_id": int64(1_796_101), "product_id": productID,
		"quantity": 1, "rent": false, "created_at": testNow, "updated_at": testNow})
	testdb.Insert(t, conn, "wishlists", map[string]any{"id": int64(1_796_103), "user_id": buyerID, "name": "Later",
		"created_at": testNow, "updated_at": testNow})
	testdb.Insert(t, conn, "wishlist_products", map[string]any{"id": int64(1_796_202), "wishlist_id": int64(1_796_103), "product_id": productID,
		"variant_id": int64(1_796_299), "recurrence": "monthly", "quantity": 2, "rent": true, "created_at": testNow, "updated_at": testNow})
	testdb.Insert(t, conn, "wishlist_products", map[string]any{"id": int64(1_796_203), "wishlist_id": int64(1_796_103), "product_id": productID,
		"quantity": 1, "rent": false, "deleted_at": testNow, "created_at": testNow, "updated_at": testNow})
	testdb.Insert(t, conn, "dashboard_nav_promotions", map[string]any{"id": int64(1_796_301), "user_id": buyerID, "nav_item": "library",
		"created_at": testNow, "updated_at": testNow})
	testdb.Insert(t, conn, "dashboard_nav_promotions", map[string]any{"id": int64(1_796_302), "user_id": buyerID, "nav_item": "seeded",
		"created_at": testNow, "updated_at": testNow})
	// The Agent tab is gone, so an old promotion of it no longer shows.
	testdb.Insert(t, conn, "dashboard_nav_promotions", map[string]any{"id": int64(1_796_303), "user_id": buyerID, "nav_item": "agent",
		"created_at": testNow, "updated_at": testNow})

	w := e.get(host, "/l/guide", e.signedIn(buyerID, nil))
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %q, Rails hit: %v", w.Code, w.Header().Get("X-Go-Web-Fallback"), e.railsHit != nil)
	}
	body := w.Body.String()
	page := html.UnescapeString(dataPage.FindStringSubmatch(body)[1])
	for _, want := range []string{
		`"logged_in_user":{"id":"1796001","email":"buyer@example.com","name":"Buyer","avatar_url":"`,
		`","confirmed":true,"team_memberships":[],"can_create_brand_account":false,"has_payout_setup_to_port":false,` +
			`"can_port_bank_payout_setup":true,"will_copy_bank_payout":false,` + teamPolicies(teamOwner) +
			`,"promoted_nav_items":["library"],"lazy_load_offscreen_discover_images":false},"current_seller":{"id":"1796001",` +
			`"email":"buyer@example.com","name":"Buyer","subdomain":"gowebbuyer.gumroad.com","avatar_url":"`,
		`","is_buyer":false,"time_zone":{"name":"America/Los_Angeles","offset":-28800},"has_published_products":false,` +
			`"can_publish_products":false,"publish_blocked_reason":"no_payout_method","no_payout_rail_in_compliance_country":false,` +
			`"legal_guardian_requirement_met":true,"legal_guardian_unsupported":false,"is_name_invalid_for_email_delivery":false,` +
			`"profile_background_color":"#ffffff","profile_highlight_color":"#ff90e8","profile_font":"ABC Favorit"},"csp_nonce":`,
		`"current_user":{"name":"Buyer","avatar_url":"`,
		`"title":"Guide \u003c1\u003e","detected_buyer_currency":null,"current_user":{"name":"Buyer","avatar_url":"`,
		`","impersonated_user":null},"prompt_passkey_setup":false,"is_mobile_app_web_view":false,`,
		`"wishlists":[{"id":"%[1]s","name":"Gifts","selections_in_wishlist":[{"variant_id":null,"recurrence":null,"rent":false,"quantity":1}]},` +
			`{"id":"%[2]s","name":"Later","selections_in_wishlist":[{"variant_id":"%[3]s","recurrence":"monthly","rent":true,"quantity":2}]}]`,
		`"currency_code":"eur","show_ratings_filter":`,
	} {
		want = strings.NewReplacer("%[1]s", e.ids.Encrypt(1_796_101), "%[2]s", e.ids.Encrypt(1_796_103), "%[3]s", e.ids.Encrypt(1_796_299)).Replace(want)
		if !strings.Contains(page, want) {
			t.Errorf("want %s", want)
		}
	}
	if !strings.Contains(body, `<meta property="gr:logged_in_user:id" content="1796001" inertia=`) {
		t.Error("gr:logged_in_user:id")
	}
}

func TestASignedInVisitorsShapes(t *testing.T) {
	for _, c := range []struct {
		name, reason, target string
		setup                func(t *testing.T, e *testEnv, conn *sql.DB)
		user                 int64
		session              map[string]any
		wants                []string
	}{
		// Their failed purchase is theirs, so the page shows none.
		{name: "a buyer of the product", wants: []string{`"purchase":null`}, setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			testdb.Insert(t, conn, "purchases", map[string]any{"id": int64(1_796_401), "link_id": productID, "seller_id": sellerID,
				"purchaser_id": buyerID, "price_cents": 500, "purchase_state": "failed", "email": "buyer@example.com",
				"created_at": testNow, "updated_at": testNow})
		}},
		// LinkPolicy#edit? lets a collaborator edit the product; nothing else changes.
		{name: "a collaborator on the product", wants: []string{`"can_edit":true,"waitlist":null,`}, setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			collaborator(t, conn, productID, nil)
		}},
		{name: "a collaborator on a waitlist product", wants: []string{`"can_edit":true,"waitlist":{"recaptcha_site_key":null,"count":1},`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				collaborator(t, conn, productID, nil)
				mustExec(t, conn, "UPDATE links SET flags = flags | ?, draft = true WHERE id = ?", productWaitlistEnabled, productID)
				testdb.Insert(t, conn, "followers", map[string]any{"id": int64(1_796_511), "followed_id": sellerID, "email": "f@example.com",
					"confirmed_at": testNow, "created_at": testNow, "updated_at": testNow})
				testdb.Insert(t, conn, "waitlist_entries", map[string]any{"id": int64(1_796_512), "follower_id": int64(1_796_511),
					"product_id": productID, "created_at": testNow, "updated_at": testNow})
			}},
		{name: "a collaborator yet to accept", wants: []string{`"can_edit":false,"waitlist":null,`}, setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			collaborator(t, conn, productID, nil)
			testdb.Insert(t, conn, "collaborator_invitations", map[string]any{"id": int64(1_796_503), "collaborator_id": int64(1_796_501),
				"created_at": testNow, "updated_at": testNow})
		}},
		{name: "a collaborator removed", wants: []string{`"can_edit":false,"waitlist":null,`}, setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			collaborator(t, conn, productID, testNow)
		}},
		// The code is evaluated for the buyer; one that doesn't exist is invalid for anyone.
		{name: "a code in the URL", target: "/l/guide/NOPE", wants: []string{`"discount_code":{"valid":false,`}},
		{name: "staff", reason: "team member", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			mustExec(t, conn, "UPDATE users SET flags = flags | ? WHERE id = ?", int64(1)<<27, buyerID)
		}},
		{name: "an unknown time zone", reason: "time zone", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			mustExec(t, conn, "UPDATE users SET timezone = 'Atlantis' WHERE id = ?", buyerID)
		}},
		{name: "a compliance country this port has no name for", reason: "compliance country", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			testdb.Insert(t, conn, "user_compliance_info", map[string]any{"id": int64(1_796_601), "user_id": buyerID, "country": "Atlantis",
				"created_at": testNow, "updated_at": testNow})
		}},
		// A seller with payouts in India: native payouts but no portable bank.
		{name: "an Indian seller's payout setup", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			testdb.Insert(t, conn, "user_compliance_info", map[string]any{"id": int64(1_796_602), "user_id": buyerID, "country": "India",
				"created_at": testNow, "updated_at": testNow})
			testdb.Insert(t, conn, "bank_accounts", map[string]any{"id": int64(1_796_603), "user_id": buyerID, "type": "IndianBankAccount",
				"created_at": testNow, "updated_at": testNow})
		}, wants: []string{`"has_payout_setup_to_port":false,"can_port_bank_payout_setup":false,"will_copy_bank_payout":false,`,
			`"no_payout_rail_in_compliance_country":false,`}},
		{name: "a portable bank", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			testdb.Insert(t, conn, "user_compliance_info", map[string]any{"id": int64(1_796_604), "user_id": buyerID, "country": "United States",
				"created_at": testNow, "updated_at": testNow})
			testdb.Insert(t, conn, "bank_accounts", map[string]any{"id": int64(1_796_605), "user_id": buyerID, "type": "AchAccount",
				"created_at": testNow, "updated_at": testNow})
		}, wants: []string{`"has_payout_setup_to_port":true,"can_port_bank_payout_setup":true,"will_copy_bank_payout":true,`}},
		// A minor outside the US can't have a guardian.
		{name: "a minor outside the US", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			testdb.Insert(t, conn, "user_compliance_info", map[string]any{"id": int64(1_796_606), "user_id": buyerID, "country": "Canada",
				"birthday": testNow.AddDate(-17, 0, 0), "created_at": testNow, "updated_at": testNow})
		}, wants: []string{`"legal_guardian_requirement_met":false,"legal_guardian_unsupported":true,`}},
		{name: "a payout setup staff rejected", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			testdb.Insert(t, conn, "comments", map[string]any{"id": int64(1_796_801), "commentable_id": buyerID, "commentable_type": "User",
				"comment_type": "payout_note", "author_id": int64(767082), "content": "No", "json_data": `{"payout_setup_rejection":true}`,
				"created_at": testNow, "updated_at": testNow})
		}, wants: []string{`"can_publish_products":false,"publish_blocked_reason":"payout_setup_rejected",`}},
		// A featured section renders its product for the same visitor, so their purchase of it counts.
		{name: "a featured product the visitor bought", wants: []string{`"review_account_name":"Buyer","should_show_receipt":true,` +
			`"was_paid":true,"is_gift_receiver_purchase":false,"show_view_content_button_on_product_page":false,` +
			`"total_price_including_tax_and_shipping":"$7","content_url":null,`}, setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			testdb.Insert(t, conn, "links", map[string]any{"id": int64(1_796_901), "user_id": sellerID, "name": "Featured",
				"unique_permalink": "gowebsf", "price_cents": 700, "created_at": testNow, "updated_at": testNow})
			testdb.Insert(t, conn, "prices", map[string]any{"id": int64(1_796_902), "link_id": int64(1_796_901), "price_cents": 700,
				"currency": "usd", "created_at": testNow, "updated_at": testNow})
			testdb.Insert(t, conn, "purchases", map[string]any{"id": int64(1_796_903), "link_id": int64(1_796_901), "seller_id": sellerID,
				"purchaser_id": buyerID, "price_cents": 700, "purchase_state": "successful", "email": "buyer@example.com",
				"displayed_price_currency_type": "usd", "total_transaction_cents": 700, "gumroad_tax_cents": 0, "created_at": testNow,
				"updated_at": testNow})
			addSection(t, conn, 1_796_904, profileFeaturedSectionType, "Pick", `{"featured_product_id":1796901}`)
			listSections(t, conn, `{"sections":[1796904]}`)
		}},
		// A featured product's props are for the same visitor, who can edit one they collaborate on.
		{name: "a featured product the visitor collaborates on", wants: []string{`"can_edit":false,"waitlist":null,`, `"can_edit":true`}, setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			testdb.Insert(t, conn, "links", map[string]any{"id": int64(1_796_901), "user_id": sellerID, "name": "Featured",
				"unique_permalink": "gowebsf", "price_cents": 700, "created_at": testNow, "updated_at": testNow})
			testdb.Insert(t, conn, "prices", map[string]any{"id": int64(1_796_902), "link_id": int64(1_796_901), "price_cents": 700,
				"currency": "usd", "created_at": testNow, "updated_at": testNow})
			collaborator(t, conn, 1_796_901, nil)
			addSection(t, conn, 1_796_904, profileFeaturedSectionType, "Pick", `{"featured_product_id":1796901}`)
			listSections(t, conn, `{"sections":[1796904]}`)
		}},
		{name: "a passkey prompt", session: map[string]any{"prompt_passkey_setup": buyerID},
			wants: []string{`"prompt_passkey_setup":true,`}},
		{name: "a name with a colon and a team", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			mustExec(t, conn, "UPDATE users SET name = 'Shop: Buyer' WHERE id = ?", buyerID)
			testdb.Insert(t, conn, "team_memberships", map[string]any{"id": int64(1_796_701), "user_id": buyerID, "seller_id": buyerID,
				"role": "owner", "created_at": testNow, "updated_at": testNow})
		}, wants: []string{`"is_name_invalid_for_email_delivery":true,`, `"team_memberships":[{"id":"%[1]s","seller_name":"Shop: Buyer","seller_avatar_url":"`,
			`","has_some_read_only_access":false,"is_selected":true}]`}},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			conn := testdb.Open(t)
			addBuyer(t, conn, nil)
			if c.setup != nil {
				c.setup(t, e, conn)
			}
			user := c.user
			if user == 0 {
				user = buyerID
			}
			target := c.target
			if target == "" {
				target = "/l/guide"
			}
			headers := e.signedIn(user, c.session)
			if c.reason != "" {
				headers["X-Go-Web-Dry-Run"] = e.dryRun(host, target, testNow)["X-Go-Web-Dry-Run"]
			}
			w := e.get(host, target, headers)
			if c.reason != "" {
				if w.Code != http.StatusNoContent || w.Header().Get("X-Go-Web-Fallback") != c.reason {
					t.Fatalf("%d %q, want fallback %q", w.Code, w.Header().Get("X-Go-Web-Fallback"), c.reason)
				}
				return
			}
			if w.Code != http.StatusOK || e.railsHit != nil {
				t.Fatalf("%d %q, Rails hit: %v", w.Code, w.Header().Get("X-Go-Web-Fallback"), e.railsHit != nil)
			}
			e.wantAll(t, html.UnescapeString(dataPage.FindStringSubmatch(w.Body.String())[1]), c.wants, 1_796_701)
		})
	}
}

func collaborator(t *testing.T, conn *sql.DB, productID int64, deletedAt any) {
	testdb.Insert(t, conn, "affiliates", map[string]any{"id": int64(1_796_501), "type": "Collaborator", "seller_id": sellerID,
		"affiliate_user_id": buyerID, "deleted_at": deletedAt, "created_at": testNow, "updated_at": testNow})
	testdb.Insert(t, conn, "affiliates_links", map[string]any{"id": int64(1_796_502), "affiliate_id": int64(1_796_501),
		"link_id": productID, "created_at": testNow, "updated_at": testNow})
}

func mustExec(t *testing.T, conn *sql.DB, query string, args ...any) {
	t.Helper()
	if _, err := conn.Exec(query, args...); err != nil {
		t.Fatal(err)
	}
}

// Several memberships list in Rails' order, the last accessed first, each with its seller.
func TestSeveralTeamMemberships(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	addBuyer(t, conn, nil)
	membership := func(id, sellerID int64, role string, accessed time.Time) {
		testdb.Insert(t, conn, "team_memberships", map[string]any{"id": id, "user_id": buyerID, "seller_id": sellerID, "role": role,
			"last_accessed_at": accessed, "created_at": testNow, "updated_at": testNow})
	}
	membership(1_796_711, buyerID, "owner", testNow.Add(-time.Hour))
	membership(1_796_712, sellerID, "support", testNow)
	// switchable leaves out a deleted seller's.
	testdb.User(t, conn, 1_796_713, map[string]any{"username": "gonegowebseller", "deleted_at": testNow})
	membership(1_796_714, 1_796_713, "admin", testNow.Add(time.Hour))
	w := e.get(host, "/l/guide", e.signedIn(buyerID, nil))
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	body := w.Body.String()
	avatar := pageProps(t, body)["product"].(map[string]any)["seller"].(map[string]any)["avatar_url"].(string)
	want := fmt.Sprintf(`"team_memberships":[{"id":"%s","seller_name":"Seller","seller_avatar_url":"%s","has_some_read_only_access":true,`+
		`"is_selected":false},{"id":"%s","seller_name":"Buyer","seller_avatar_url":"%s","has_some_read_only_access":false,"is_selected":true}]`,
		e.ids.Encrypt(1_796_712), avatar, e.ids.Encrypt(1_796_711), avatar)
	if page := html.UnescapeString(dataPage.FindStringSubmatch(body)[1]); !strings.Contains(page, want) {
		t.Errorf("want %s\nin %s", want, page)
	}
}
