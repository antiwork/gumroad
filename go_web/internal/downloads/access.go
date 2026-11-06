package downloads

import (
	"encoding/json"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// checkPermissions runs fetch_url_redirect, redirect_bundle_purchase_to_library_if_needed,
// redirect_to_coffee_page_if_needed and check_permissions as a poll meets them. It returns
// the redirect a filter answers with (a path is on the request's host), or the url redirect
// the poll reads when every filter passes.
func (h *handler) checkPermissions(p *page) (*urlRedirect, string, error) {
	db := h.c.DB
	u, err := findURLRedirect(p.Ctx, db, p.Req.Params.Value("id").(string))
	if err != nil {
		return nil, "", err
	}
	if u == nil {
		return nil, "", errNotFound
	}
	if u.installmentID != nil {
		// A post's content: fetch_url_redirect's withdrawn-content rules and the post's files.
		return nil, "", fallback("installment")
	}
	var purchase *purchase
	if u.purchaseID != nil {
		if purchase, err = findPurchase(p.Ctx, db, *u.purchaseID); err != nil {
			return nil, "", err
		}
	}
	p.purchase = purchase
	if purchase != nil && purchase.bundle() {
		return nil, "", fallback("bundle purchase")
	}
	imported, importedType, err := importedCustomer(p.Ctx, db, u)
	if err != nil {
		return nil, "", err
	}
	nativeType := (*string)(nil)
	if purchase != nil {
		nativeType = purchase.productNativeType
	} else if nativeType, err = referencedProductNativeType(p.Ctx, db, u, imported, importedType); err != nil {
		return nil, "", err
	}
	if nativeType != nil && *nativeType == coffeeNativeType {
		return nil, "", fallback("coffee product")
	}

	token := u.token
	if purchase != nil && purchase.refundedOrChargedBack() {
		// withdrawn_content_response moves a poll to the expired page, and raises e404 for
		// the page itself.
		if !p.poll {
			return nil, "", errNotFound
		}
		return nil, "/r/" + token + "/expired", nil
	}

	signedIn := p.Auth.CurrentUser != nil
	logged := p.Auth.LoggedInUser()
	var subscription *subscription
	if purchase != nil && purchase.subscriptionID != nil {
		if subscription, err = findSubscription(p.Ctx, db, *purchase.subscriptionID); err != nil {
			return nil, "", err
		}
	}
	// viewer_owns_subscription? ends with the true original purchase's gift, which this port
	// leaves to Rails. It only changes the outcome when the viewer isn't the purchaser.
	if signedIn && purchase != nil && !purchase.giftReceiver() && subscription != nil && subscription.userID != nil &&
		*subscription.userID == logged.ID && !purchase.purchaserIs(logged.ID) {
		return nil, "", fallback("subscription owner")
	}

	// Each condition reads is_test_purchase? and grant_access_to_product? only where Ruby's
	// && reaches them, since both raise on a missing product.
	if purchase != nil && signedIn && purchase.purchaserID != nil && !purchase.purchaserIs(logged.ID) && !logged.IsTeamMember() {
		test, err := purchase.testPurchase()
		if err != nil {
			return nil, "", err
		}
		if !test {
			return nil, "/r/" + token + "/check_purchaser?" + rails.ToQuery([2]string{"next", p.Req.Path}), nil
		}
	}
	if purchase != nil && purchase.rentalExpired {
		return nil, "/r/" + token + "/rental_expired", nil
	}
	if purchase != nil && purchase.accessRevoked() {
		return nil, "/r/" + token + "/expired", nil
	}
	if subscription != nil {
		granted, err := subscription.grantAccessToProduct(p.Req.Now)
		if err != nil {
			return nil, "", err
		}
		if !granted {
			return nil, "/r/" + token + "/membership_inactive", nil
		}
	}

	test := false
	if purchase != nil {
		if test, err = purchase.testPurchase(); err != nil {
			return nil, "", err
		}
	}
	if test {
		if logged != nil && (purchase.purchaserIs(logged.ID) || logged.IsTeamMember()) {
			return u, "", nil
		}
		if signedIn {
			return nil, "", errNotFound
		}
		return nil, h.c.Env.Protocol + "://" + h.c.Env.Domain + "/login?" + rails.ToQuery([2]string{"next", p.Req.FullPath()}), nil
	}

	// Every check from here lets the poll through except the last, so the cheapest goes first.
	if !u.hasBeenSeen() || purchase == nil || imported || rails.SecureCompare(h.confirmedCookie(p), token) ||
		(logged != nil && purchase.purchaserIs(logged.ID)) || remoteIPMatches(p, purchase.ipAddress) {
		return u, "", nil
	}
	query := [][2]string{{"id", token}, {"destination", "download_page"}}
	if display, _ := p.Req.Params.Value("display").(string); rails.Present(display) {
		query = append(query, [2]string{"display", display})
	}
	return nil, "/confirm?" + rails.ToQuery(query...), nil
}

// confirmedCookie is cookies.encrypted[:confirmed_redirect], "" when absent or unreadable.
func (h *handler) confirmedCookie(p *page) string {
	plain, ok := h.c.Store.EncryptedCookie(p.Req, confirmedCookie)
	if !ok {
		return ""
	}
	var token string
	if json.Unmarshal(plain, &token) != nil {
		return ""
	}
	return token
}

func remoteIPMatches(p *page, ip *string) bool {
	if ip == nil {
		return false
	}
	remote, err := p.Req.RemoteIP()
	return err == nil && rails.SecureCompare(*ip, remote)
}
