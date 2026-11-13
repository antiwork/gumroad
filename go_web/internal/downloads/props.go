package downloads

import (
	"context"
	"database/sql"
	"errors"

	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

// discordProp is content_props' discord: {connected:} when DiscordIntegration.is_enabled_for
// the purchase, else nil.
func (h *handler) discordProp(ctx context.Context, pu *purchase, d *pageData) (any, error) {
	if !d.discordIntegration {
		return nil, nil
	}
	integrationID, err := h.enabledDiscordIntegration(ctx, pu, d)
	if err != nil || integrationID == nil {
		return nil, err
	}
	// discord_user_id_for: live_purchase_integrations.find_by(integration:).try(:discord_user_id)
	var userID sql.NullString
	err = h.c.DB.QueryRowContext(ctx, "SELECT discord_user_id FROM purchase_integrations WHERE purchase_id = ?"+
		" AND deleted_at IS NULL AND integration_id = ? LIMIT 1", pu.id, *integrationID).Scan(&userID)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	return rails.NewRHash().Sym("connected", rails.Present(userID.String)), nil
}

// enabledDiscordIntegration is Purchase#find_enabled_integration("discord")'s id: the first
// purchased variant's, unless the product is physical, else the product's.
func (h *handler) enabledDiscordIntegration(ctx context.Context, pu *purchase, d *pageData) (*int64, error) {
	const discord = "DiscordIntegration"
	if !d.productIs(productIsPhysical) {
		// variant_attributes.present? loads the habtm rows unordered, and .first takes the first.
		variants, err := h.int64s(ctx, "SELECT base_variants.id FROM base_variants INNER JOIN base_variants_purchases"+
			" ON base_variants.id = base_variants_purchases.base_variant_id WHERE base_variants_purchases.purchase_id = ?", pu.id)
		if err != nil {
			return nil, err
		}
		if len(variants) > 0 {
			var found *int64
			for i, v := range variants {
				id, err := h.firstID(ctx, "SELECT integrations.id FROM integrations INNER JOIN base_variant_integrations"+
					" ON integrations.id = base_variant_integrations.integration_id WHERE base_variant_integrations.base_variant_id = ?"+
					" AND base_variant_integrations.deleted_at IS NULL AND integrations.type = ? ORDER BY integrations.id ASC LIMIT 1", v, discord)
				if err != nil {
					return nil, err
				}
				if i == 0 {
					found = id
				} else if (id == nil) != (found == nil) || id != nil && *id != *found {
					// Which variant MySQL lists first decides; with variants that disagree, Rails reads it.
					return nil, fallback("variant integrations")
				}
			}
			return found, nil
		}
	}
	return h.firstID(ctx, "SELECT integrations.id FROM integrations INNER JOIN product_integrations"+
		" ON integrations.id = product_integrations.integration_id WHERE product_integrations.product_id = ?"+
		" AND product_integrations.deleted_at IS NULL AND integrations.type = ? ORDER BY integrations.id ASC LIMIT 1", d.productID, discord)
}

// firstID is the first column of a query's first row, nil without one.
func (h *handler) firstID(ctx context.Context, query string, args ...any) (*int64, error) {
	var id int64
	err := h.c.DB.QueryRowContext(ctx, query, args...).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &id, nil
}

// communityChatURL is UrlRedirectPresenter#community_chat_url for a signed-out viewer, with
// referencedID the url redirect's referenced_link.
func (h *handler) communityChatURL(ctx context.Context, d *pageData, referencedID *int64) (any, error) {
	if referencedID == nil {
		// product.community_chat_enabled? raises on a nil referenced_link.
		return nil, fallback("no referenced product")
	}
	flags := d.productFlags
	if *referencedID != d.productID {
		if err := h.c.DB.QueryRowContext(ctx, "SELECT flags FROM links WHERE id = ? LIMIT 1", *referencedID).Scan(&flags); err != nil {
			return nil, err
		}
	}
	if flags&productCommunityChatEnabled == 0 {
		return nil, nil
	}
	// has_one :active_community, -> { alive }, as: :resource
	community, err := h.firstID(ctx, "SELECT communities.id FROM communities WHERE communities.deleted_at IS NULL"+
		" AND communities.resource_id = ? AND communities.resource_type = 'Link' LIMIT 1", *referencedID)
	if err != nil || community == nil {
		return nil, err
	}
	switch {
	case !d.sellerExternalID.Valid:
		// community_path raises on a nil seller_id.
		return nil, fallback("seller external_id")
	case !d.email.Valid:
		// The path helpers drop a nil email.
		return nil, fallback("community chat email")
	}
	path := "/communities/" + web.EscapeSegment(d.sellerExternalID.String) + "/" + web.EscapeSegment(h.c.IDs.Encrypt(*community))
	query := rails.ToQuery([2]string{"email", d.email.String}, [2]string{"next", path})
	if !d.purchaserIDColumn.Valid {
		return "/signup?" + query, nil
	}
	return "/login?" + query, nil
}

// receiptPurchase is Purchase#receipt_purchase's id and has_invoice? for a purchase without a
// subscription: a bundle member's is the bundle purchase it came with, when that one isn't a
// gift and has the same email.
func (h *handler) receiptPurchase(ctx context.Context, pu *purchase, d *pageData) (int64, bool, error) {
	if pu.flags&purchaseIsBundleProduct == 0 {
		return pu.id, !d.freePurchase(), nil
	}
	var id, flags int64
	var email sql.NullString
	var subscriptionID, price, shipping sql.NullInt64
	err := h.c.DB.QueryRowContext(ctx, "SELECT purchases.id, purchases.email, purchases.flags, purchases.subscription_id,"+
		" purchases.price_cents, purchases.shipping_cents FROM purchases INNER JOIN bundle_product_purchases"+
		" ON purchases.id = bundle_product_purchases.bundle_purchase_id WHERE bundle_product_purchases.product_purchase_id = ? LIMIT 1",
		pu.id).Scan(&id, &email, &flags, &subscriptionID, &price, &shipping)
	if errors.Is(err, sql.ErrNoRows) {
		return pu.id, !d.freePurchase(), nil
	}
	if err != nil {
		return 0, false, err
	}
	if id == pu.id || flags&purchaseIsGiftSender != 0 || email != d.email {
		return pu.id, !d.freePurchase(), nil
	}
	if subscriptionID.Valid {
		return 0, false, fallback("bundle purchase subscription")
	}
	bundle := pageData{priceCents: price, shippingCents: shipping}
	return id, !bundle.freePurchase(), nil
}
