package products

import (
	"fmt"
	"html"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/elastic"
	"github.com/antiwork/gumroad/go_web/internal/session"
	"github.com/antiwork/gumroad/go_web/internal/session/sessiontest"
	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
)

// actingAs adds the current_seller_id cookie switch_seller_account writes.
func (e *testEnv) actingAs(headers map[string]string, sellerID int64) map[string]string {
	cookie := sessiontest.Encrypt(e.t, testSecretKeyBase, session.CurrentSellerCookie, []byte(strconv.FormatInt(sellerID, 10)), time.Time{})
	headers["Cookie"] += "; " + session.CurrentSellerCookie + "=" + url.QueryEscape(cookie)
	return headers
}

// teamPolicies is logged_in_user's policies for a role on the current seller, the owner's on
// their own account, without communities or the store agent.
func teamPolicies(role string) string {
	is := func(roles ...string) string {
		return strconv.FormatBool(role == teamOwner || slices.Contains(roles, role))
	}
	write := is(teamAdmin, teamMarketing)
	all := is(teamAccountant, teamAdmin, teamMarketing, teamSupport)
	return `"policies":{"affiliate_requests_onboarding_form":{"update":` + write + `},"direct_affiliate":{"create":` + write + `,"update":` + write + `},` +
		`"collaborator":{"create":` + is(teamAdmin) + `,"update":` + is(teamAdmin) + `},"product":{"create":` + write + `},` +
		`"product_review_response":{"update":` + is(teamAdmin, teamSupport) + `},` +
		`"balance":{"index":` + is(teamAccountant, teamAdmin, teamSupport) + `,"export":` + is(teamAccountant, teamAdmin, teamSupport) + `},` +
		`"checkout_offer_code":{"create":` + write + `},"checkout_form":{"update":` + write + `},"upsell":{"create":` + write + `},` +
		`"settings_payments_user":{"show":` + is(teamAdmin) + `},"settings_main_user":{"update_username":` + is() + `},` +
		`"settings_profile":{"manage_social_connections":` + is() + `,"update":` + write + `},` +
		`"settings_third_party_analytics_user":{"update":` + is(teamAdmin) + `},"installment":{"create":` + write + `},` +
		`"workflow":{"create":` + write + `},"utm_link":{"index":` + all + `},"community":{"index":false},"churn":{"show":` + all + `},` +
		`"page":{"index":` + all + `,"create":` + write + `}}`
}

// A team member viewing a product as the seller they switched to: their role decides can_edit
// and the policies, and the seller's wishlists, props and memberships' selection follow the
// seller. The seller viewing their own product as another team's sees it as a visitor does, in
// the storefront.
func TestATeamMemberActingAsAnotherSeller(t *testing.T) {
	for _, c := range []struct {
		role, edits string
		// owner is the product's seller signed in, acting as the buyer's account.
		owner bool
	}{
		{role: teamAdmin, edits: "true"},
		{role: teamMarketing, edits: "true"},
		{role: teamSupport, edits: "false"},
		{role: teamAccountant, edits: "false"},
		{role: teamAdmin, edits: "false", owner: true},
	} {
		name := c.role
		if c.owner {
			name = "the seller as an " + c.role
		}
		t.Run(name, func(t *testing.T) {
			e := newTestEnv(t)
			conn := testdb.Open(t)
			addBuyer(t, conn, nil)
			mustExec(t, conn, "UPDATE users SET email = 'seller@example.com', confirmed_at = ?, timezone = 'Pacific Time (US & Canada)',"+
				" flags = flags | ? WHERE id = ?", testNow, userProductPageStorefrontEnabled, sellerID)
			// The storefront's default section, newest first: one sort value per hit.
			server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				io.WriteString(w, fmt.Sprintf(`{"hits":{"total":{"value":2,"relation":"eq"},"hits":[{"_id":"%d","sort":[1762430000000]},`+
					`{"_id":"%d","sort":[1762420000000]}]},"aggregations":{"tags.keyword":{"buckets":[]},"filetypes.keyword":{"buckets":[]}}}`,
					ownOther, productID))
			}))
			t.Cleanup(server.Close)
			client, err := elastic.NewWithClient(server.URL, server.Client())
			if err != nil {
				t.Fatal(err)
			}
			e.config.Page.Search = client
			testdb.Insert(t, conn, "links", map[string]any{"id": ownOther, "user_id": sellerID, "name": "Other", "unique_permalink": "gowebown2",
				"price_cents": 300, "created_at": testNow, "updated_at": testNow})
			testdb.Insert(t, conn, "prices", map[string]any{"id": int64(1_799_002), "link_id": ownOther, "price_cents": 300, "currency": "usd",
				"created_at": testNow, "updated_at": testNow})
			member, team := int64(buyerID), int64(sellerID)
			if c.owner {
				member, team = sellerID, buyerID
			}
			membership := func(id, seller int64, role string, accessed time.Time) {
				testdb.Insert(t, conn, "team_memberships", map[string]any{"id": id, "user_id": member, "seller_id": seller, "role": role,
					"last_accessed_at": accessed, "created_at": testNow, "updated_at": testNow})
			}
			membership(1_799_401, member, teamOwner, testNow.Add(-time.Hour))
			membership(1_799_402, team, c.role, testNow)
			for i, owner := range []int64{member, team} {
				testdb.Insert(t, conn, "wishlists", map[string]any{"id": int64(1_799_411 + i), "user_id": owner, "name": "List " + strconv.Itoa(i),
					"created_at": testNow, "updated_at": testNow})
			}

			headers := e.actingAs(e.signedIn(member, map[string]any{"prompt_passkey_setup": member}), team)
			w := e.get(host, "/l/guide", headers)
			if w.Code != http.StatusOK || e.railsHit != nil {
				dry := e.get(host, "/l/guide", e.withDryRun("/l/guide", headers, "any"))
				t.Fatalf("%d, dry run %q", w.Code, dry.Header().Get("X-Go-Web-Fallback"))
			}
			component := productComponent
			teamEmail, teamExternal, published := "seller@example.com", "1790001", "true"
			if c.owner {
				component, teamEmail, teamExternal, published = storefrontComponent, "buyer@example.com", "1796001", "false"
			}
			componentProps(t, w.Body.String(), component)
			page := html.UnescapeString(dataPage.FindStringSubmatch(w.Body.String())[1])
			readOnly := strconv.FormatBool(c.role != teamAdmin)
			list := `{"id":"` + e.ids.Encrypt(1_799_412) + `","name":"List 1"`
			for _, want := range []string{
				teamPolicies(c.role),
				`"has_some_read_only_access":` + readOnly + `,"is_selected":true},{"id":"` + e.ids.Encrypt(1_799_401) + `",`,
				`"has_some_read_only_access":false,"is_selected":false}],`,
				`"current_seller":{"id":"` + teamExternal + `","email":"` + teamEmail + `",`,
				`"has_published_products":` + published + `,`,
				`"prompt_passkey_setup":false,`,
				`"can_edit":` + c.edits + `,"waitlist":null,`,
				`"is_verified":false,"can_edit":` + c.edits + `,`,
				`"wishlists":[` + list + `,"selections_in_wishlist":[]}]`,
			} {
				if !strings.Contains(page, want) {
					t.Errorf("want %s\nin %s", want, page)
				}
			}
			// The editor's wishlist_options are the seller's, on their own product alone.
			if got := strings.Contains(page, `"wishlist_options":[`+list+`}]`); got == c.owner {
				t.Errorf("wishlist_options %v", got)
			}
		})
	}
}

// can_publish_products? lets a staff seller publish, which this port leaves to Rails.
func TestATeamMemberActingAsAStaffSeller(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	addBuyer(t, conn, nil)
	mustExec(t, conn, "UPDATE users SET flags = flags | ? WHERE id = ?", 1<<27, sellerID)
	for i, seller := range []int64{buyerID, sellerID} {
		testdb.Insert(t, conn, "team_memberships", map[string]any{"id": int64(1_799_421 + i), "user_id": buyerID, "seller_id": seller,
			"role": []string{teamOwner, teamAdmin}[i], "created_at": testNow, "updated_at": testNow})
	}
	headers := e.withDryRun("/l/guide", e.actingAs(e.signedIn(buyerID, nil), sellerID), "staff current seller")
	if w := e.get(host, "/l/guide", headers); w.Header().Get("X-Go-Web-Fallback") != "staff current seller" {
		t.Errorf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
}
