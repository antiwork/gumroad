package beacons

import (
	"encoding/json"
	"net/http"
	"regexp"
	"strconv"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// Event::PERMITTED_NAMES, the names kept without a user.
var permittedEventNames = map[string]bool{
	"add_product_mobile_app": true, "audience_callout_dismissal": true, "chargeback": true,
	"delete_product_mobile_app": true, "edit_product_mobile_app": true, "first_purchase_on_profile_visit": true,
	"post_view": true, "product_purchase_recovery_click": true, "product_refund_policy_fine_print_view": true,
	"purchase": true, "refund": true, "service_charge": true, "settlement_declined": true,
	"social_connect_attempted": true, "social_connect_connected": true, "social_connect_failed": true,
	"social_connect_hold_released": true, "social_connect_offered": true, "social_connect_reviewed": true,
}

// Event's has_flags on visit_id.
const (
	flagWasProductRecommended = 1 << 1
	flagOnCustomDomain        = 1 << 4
	flagFromMultiOverlay      = 1 << 5
	flagFromSEO               = 1 << 6
)

var seoReferrer = regexp.MustCompile(`(?i)(google|bing|yahoo|yandex|duckduckgo)(\.[a-z]{2,3})(\.[a-z]{2})?$`)

// trackUserAction is LinksController#track_user_action.
func (h *handlers) trackUserAction(c *actionContext) error {
	product, err := h.fetchProduct(c)
	if err != nil {
		return err
	}
	// logged_in_user == @product.user; nil == nil when the owner row is gone.
	logged := c.auth.LoggedInUser()
	ownerSignedIn := (logged == nil && !product.ownerExists) || (logged != nil && product.ownerExists && logged.ID == product.userID)
	if !ownerSignedIn {
		if err := h.createUserEvent(c, product); err != nil {
			return err
		}
	}
	rails.RenderStaticJSON(c.w, c.req, http.StatusOK, successTrue)
	return nil
}

// createEvent is EventsController#create.
func (h *handlers) createEvent(c *actionContext) error {
	if err := h.createUserEvent(c, nil); err != nil {
		return err
	}
	rails.RenderStaticJSON(c.w, c.req, http.StatusOK, successTrue)
	return nil
}

// createUserEvent is Events#create_user_event(params[:event_name]) and the private
// create_event it calls.
func (h *handlers) createUserEvent(c *actionContext, product *product) error {
	req := c.req
	name, hasName := req.Params.Get("event_name")
	if !hasName || name == nil || c.auth.Impersonating() {
		return nil
	}
	table := "events"
	if name == "signup" {
		table = "signup_events"
	}
	var userID any
	if logged := c.auth.LoggedInUser(); logged != nil {
		userID = logged.ID
	}
	nameString, isString := name.(string)
	if table == "events" && (!isString || !permittedEventNames[nameString]) && userID == nil {
		return nil
	}
	// Event validates purchase_id and link_id for purchases; RecordInvalid is a 422.
	if name == "purchase" {
		return statusError(http.StatusUnprocessableEntity)
	}

	ip, err := req.RemoteIP()
	if err != nil {
		return err
	}
	geo := h.deps.GeoIP.Lookup(ip)
	referrer := rails.LastPresent(req.Param("referrer"))
	if !rails.Truthy(referrer) {
		referrer = stringOrNil(req.Referrer())
	}
	if referrer, err = asciiReferrer(referrer); err != nil {
		return err
	}

	var flags int64
	if flagTrue(req.Param("from_multi_overlay")) {
		flags |= flagFromMultiOverlay
	}
	if c.session != nil && seoReferrerPresent(c.session.Get("signup_referrer")) {
		flags |= flagFromSEO
	}
	recommended := flagTrue(req.Param("was_product_recommended"))
	if recommended {
		flags |= flagWasProductRecommended
	}
	domain := referrerDomain(asStringPtr(referrer))
	if recommended {
		domain = recommendedReferrerDomain
	}
	viewURL := req.Param("view_url")
	if !rails.Truthy(viewURL) {
		viewURL = req.Path
	}
	var linkID, priceCents any
	if product != nil {
		linkID = product.id
		if product.priceCents.Valid {
			priceCents = product.priceCents.Int64
		}
	}
	var country, state any
	if geo != nil {
		country, state = stringOrNil(geo.CountryName), stringOrNil(geo.RegionName)
	}
	// String columns get #to_s of what they're given; for a hash or array param that is
	// its inspect, which no reader wants, so such an event is dropped instead.
	eventName, nameOK := rails.ColumnString(name)
	parentReferrer, parentOK := rails.ColumnString(req.Param("parent_referrer"))
	viewURLColumn, viewOK := rails.ColumnString(viewURL)
	fingerprint, fingerprintOK := browserFingerprint(req)
	if !nameOK || !parentOK || !viewOK || !fingerprintOK {
		c.logger().Info("Skipping an event with a non-scalar string param")
		return nil
	}
	// Rails' Time.current goes through a precision-0 column: truncated, not rounded.
	now := req.Now.UTC().Truncate(time.Second)

	ctx, cancel := c.writeContext()
	defer cancel()
	_, err = h.deps.DB.ExecContext(ctx, `INSERT INTO `+table+` (visit_id, ip_address, event_name, user_id, link_id,
		created_at, updated_at, referrer, parent_referrer, browser, is_mobile, price_cents, view_url, ip_country,
		ip_longitude, ip_latitude, is_modal, browser_fingerprint, browser_guid, referrer_domain, ip_state)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?, ?, ?)`,
		flags, ip, eventName, userID, linkID, now, now, referrer, parentReferrer,
		stringOrNil(req.UserAgent()), isMobile(c), priceCents, viewURLColumn, country,
		rails.BooleanCast(req.Param("is_modal")), fingerprint, cookieOrNil(req), domain, state)
	return err
}

func isMobile(c *actionContext) bool {
	ua := ""
	if v := c.req.UserAgent(); v != nil {
		ua = *v
	}
	return c.session.IsMobile(ua)
}

// seoReferrerPresent is Events#seo_referrer?(session[:signup_referrer]).
func seoReferrerPresent(v any) bool {
	s, isString := v.(string)
	return isString && rails.Present(s) && seoReferrer.MatchString(s)
}

func cookieOrNil(req *rails.Request) any {
	if v, ok := req.Cookie(guidCookie); ok {
		return v
	}
	return nil
}

// flagTrue is FlagShihTzu::TRUE_VALUES.include?(value), which its setters test.
func flagTrue(v any) bool {
	switch v := v.(type) {
	case bool:
		return v
	case string:
		switch v {
		case "1", "t", "T", "true", "TRUE":
			return true
		}
	case json.Number:
		n, err := strconv.ParseFloat(string(v), 64)
		return err == nil && n == 1
	}
	return false
}
