package products

import (
	"context"
	"database/sql"
	"errors"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/flipper"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// exists runs a SELECT 1 query.
func (h *handler) exists(ctx context.Context, query string, args ...any) (bool, error) {
	var one int
	err := h.c.DB.QueryRowContext(ctx, query, args...).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// scanIDs is the id of each row a statement returns, in its order.
func (h *handler) scanIDs(ctx context.Context, query string, args ...any) ([]int64, error) {
	var ids []int64
	err := scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
		var id int64
		cols["id"] = &id
		return func() { ids = append(ids, id) }
	}, query, args...)
	return ids, err
}

// unportedProductShape is the product itself, as the page and the custom HTML wrapper both
// read it.
func unportedProductShape(prod *product) string {
	membership := unportedMembership(prod)
	switch {
	case !prod.purchaseType.Valid || prod.purchaseType.Int64 < purchaseTypeBuyOnly || prod.purchaseType.Int64 > purchaseTypeBuyAndRent:
		return "purchase type"
	case membership != "":
		return membership
	case !prod.uniquePermalink.Valid:
		return "no unique permalink"
	}
	return ""
}

// unportedShape is a product this port leaves to Rails: a check per part of the page whose
// Rails path it doesn't follow. Each runs before anything is written.
func (h *handler) unportedShape(ctx context.Context, p *page, prod *product) (string, error) {
	seller := p.seller
	switch {
	case prod.nativeType == "call" && h.c.Page.CalendarHref == "":
		// The calendar preload's vite_asset_path raises.
		return "call calendar asset", nil
	case seller.is(userProductPageStorefrontEnabled) && h.c.Page.Search == nil:
		return "storefront", nil
	case prod.is(productShouldShowSalesCount) && h.c.Page.Search == nil:
		return "sales count", nil
	}
	if reason := unportedProductShape(prod); reason != "" {
		return reason, nil
	}
	// account_level_refund_policy_enabled?: the seller's policy shows unless it's off for all.
	if seller.is(userRefundPolicyEnabled) {
		off, err := h.c.Page.Flag("seller_refund_policy_disabled_for_all").Active(ctx)
		if errors.Is(err, flipper.ErrUnevaluable) || err == nil && !off {
			return "seller refund policy", nil
		}
		if err != nil {
			return "", err
		}
	}
	// These aren't fallbacks: they spare a lookup on products that have none.
	gates := []struct {
		query string
		arg   int64
		dest  *bool
	}{
		{"SELECT 1 FROM affiliates_links INNER JOIN affiliates ON affiliates.id = affiliates_links.affiliate_id" +
			" WHERE affiliates_links.link_id = ? AND affiliates.type = 'Collaborator'", prod.id, &p.hasCollaborator},
		{"SELECT 1 FROM product_installment_plans WHERE product_installment_plans.link_id = ?" +
			" AND product_installment_plans.deleted_at IS NULL", prod.id, &p.hasInstallmentPlan},
		{"SELECT 1 FROM public_files WHERE public_files.resource_type = 'Link' AND public_files.resource_id = ?" +
			" AND public_files.deleted_at IS NULL", prod.id, &p.hasPublicFiles},
		// bundle_products renders them whether or not the product is still a bundle.
		{"SELECT 1 FROM bundle_products WHERE bundle_products.bundle_id = ? AND bundle_products.deleted_at IS NULL", prod.id, &p.hasBundleProducts},
		{"SELECT 1 FROM offer_codes WHERE " + autoApplyCodes, seller.id, &p.hasAutoApplyCode},
		{"SELECT 1 FROM seller_profile_sections WHERE seller_profile_sections.product_id = ?", prod.id, &p.hasProductSections},
	}
	// One round trip; each EXISTS stops at its first row.
	exprs, args, dest := make([]string, 0, len(gates)), make([]any, 0, len(gates)), make([]any, 0, len(gates))
	for _, g := range gates {
		exprs, args, dest = append(exprs, "EXISTS("+g.query+")"), append(args, g.arg), append(dest, g.dest)
	}
	if err := h.c.DB.QueryRowContext(ctx, "SELECT "+strings.Join(exprs, ", "), args...).Scan(dest...); err != nil {
		return "", err
	}
	return "", nil
}

const guidCookie = "_gumroad_guid"

// jsonData is a json_data column as the JSON coder loads it.
type jsonData struct{ h *rails.Hash }

// parseJSONData is false where Rails raises: text the coder can't load, or a value that
// isn't a Hash (JsonData#json_data).
func parseJSONData(s sql.NullString) (jsonData, bool) {
	if !s.Valid || s.String == "" {
		return jsonData{}, true
	}
	v, err := rails.ParseJSON([]byte(s.String))
	if err != nil {
		return jsonData{}, false
	}
	switch v := v.(type) {
	case nil:
		return jsonData{}, true
	case *rails.Hash:
		return jsonData{v}, true
	}
	return jsonData{}, false
}

// get is json_data[key].
func (j jsonData) get(key string) any {
	if j.h == nil {
		return nil
	}
	return j.h.Value(key)
}

// present is json_data_for_attr's json_data[attribute].present?.
func (j jsonData) present(key string) (any, bool) {
	v := j.get(key)
	return v, rails.Present(v)
}
