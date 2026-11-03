package beacons

import (
	"database/sql"
	"errors"
	"net/http"
	"strconv"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// cartItemsCount is LinksController#cart_items_count's format.json branch. The Inertia
// branch stays in Rails, so a request whose negotiation lands there was misrouted.
func (h *handlers) cartItemsCount(c *actionContext) error {
	if rails.Negotiate(c.req.Formats, "json", rails.AnyFormat) != "json" {
		c.logger().Error("cart_items_count reached go_web without negotiating JSON", "accept", c.req.HTTP.Header.Get("Accept"))
		rails.RenderEmpty(c.w, c.req, http.StatusNotAcceptable)
		return nil
	}
	count, err := h.cartCount(c)
	if err != nil {
		return err
	}
	rails.RenderJSON(c.w, c.req, http.StatusOK, `{"cart_items_count":`+strconv.FormatInt(count, 10)+`}`)
	return nil
}

// cartCount is Cart.fetch_by(user: logged_in_user, browser_guid:)&.cart_products&.alive&.count.
// A guid minted for this request has no cart yet.
func (h *handlers) cartCount(c *actionContext) (int64, error) {
	const count = `SELECT (SELECT COUNT(*) FROM cart_products WHERE cart_products.cart_id = carts.id AND cart_products.deleted_at IS NULL) FROM carts `
	var n int64
	var err error
	if logged := c.auth.LoggedInUser(); logged != nil {
		err = h.deps.DB.QueryRowContext(c.ctx, count+`WHERE carts.user_id = ? AND carts.deleted_at IS NULL ORDER BY carts.id ASC LIMIT 1`, logged.ID).Scan(&n)
	} else if guid, ok := c.req.Cookie(guidCookie); ok && !c.guidMinted && rails.Present(guid) {
		err = h.deps.DB.QueryRowContext(c.ctx, count+`WHERE carts.deleted_at IS NULL AND carts.browser_guid = ? AND carts.user_id IS NULL LIMIT 1`, guid).Scan(&n)
	} else {
		return 0, nil
	}
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	return n, err
}
