package products

import (
	"context"
	"database/sql"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/viewer"
)

// signedInUser is the signed-in visitor, or the seller they act as, with what only the product
// page reads of them.
type signedInUser struct {
	*viewer.User
	wishlists []*viewerWishlist
}

// loadViewer loads the signed-in visitor, the seller they view the product as, and the
// signed-in share's props.
func (h *handler) loadViewer(p *page, prod *product) error {
	v, err := h.c.Page.Viewers.Load(p.Ctx, p.Req, p.Session, p.Auth)
	if err != nil || v == nil {
		return err
	}
	// The page's first avatar reads are these.
	if len(v.AvatarResizes) > 0 && h.c.Page.Sidekiq == nil {
		return fallback("avatar variant push")
	}
	p.viewerPushes = v.AvatarResizes
	u := &signedInUser{User: v.User}
	seller := u
	if v.Seller != v.User {
		seller = &signedInUser{User: v.Seller}
	}
	p.viewer, p.currentSeller, p.teamRole, p.share = u, seller, v.Role, v
	if seller.wishlists, err = h.loadViewerWishlists(p.Ctx, seller.ID); err != nil {
		return err
	}
	return h.viewerCollaborates(p, prod)
}

// collaboratorFor is User#collaborator_for?.
func (h *handler) collaboratorFor(ctx context.Context, userID, productID int64) (bool, error) {
	return h.exists(ctx, "SELECT 1 FROM links INNER JOIN affiliates_links ON links.id = affiliates_links.link_id"+
		" INNER JOIN affiliates ON affiliates_links.affiliate_id = affiliates.id"+
		" LEFT OUTER JOIN collaborator_invitations ON collaborator_invitations.collaborator_id = affiliates.id"+
		" WHERE affiliates.type = 'Collaborator' AND affiliates.affiliate_user_id = ? AND collaborator_invitations.id IS NULL"+
		" AND affiliates.deleted_at IS NULL AND links.id = ? LIMIT 1", userID, productID)
}

// viewerCollaborates sets p.collaborates for the page's product. It reads unportedShape's
// hasCollaborator gate, so it must run after it, or it finds no collaborator.
func (h *handler) viewerCollaborates(p *page, prod *product) error {
	if p.viewer == nil || !p.hasCollaborator {
		return nil
	}
	var err error
	p.collaborates, err = h.collaboratorFor(p.Ctx, p.viewer.ID, prod.id)
	return err
}

// viewerCurrency is ProfileSectionsPresenter's currency_code: the visitor's currency_type.
func viewerCurrency(p *page) any {
	if p.viewer != nil && p.viewer.CurrencyType.Valid {
		return p.viewer.CurrencyType.String
	}
	return "usd"
}

// viewerWishlist is one of the current seller's alive wishlists and its alive items.
type viewerWishlist struct {
	id    int64
	name  sql.NullString
	items []wishlistItem
}

type wishlistItem struct {
	productID         int64
	variant, quantity sql.NullInt64
	recurrence        sql.NullString
	rent              sql.NullBool
}

// loadViewerWishlists is seller.wishlists.alive.includes(:alive_wishlist_products), in Rails' own
// statements: neither sets an order, so the plan MySQL picks for them decides it.
func (h *handler) loadViewerWishlists(ctx context.Context, userID int64) ([]*viewerWishlist, error) {
	var lists []*viewerWishlist
	err := scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
		w := &viewerWishlist{}
		cols["id"], cols["name"] = &w.id, &w.name
		return func() { lists = append(lists, w) }
	}, "SELECT `wishlists`.* FROM `wishlists` WHERE `wishlists`.`user_id` = ? AND `wishlists`.`deleted_at` IS NULL", userID)
	if err != nil || len(lists) == 0 {
		return lists, err
	}
	byID := map[int64]*viewerWishlist{}
	ids := make([]int64, len(lists))
	for i, w := range lists {
		byID[w.id], ids[i] = w, w.id
	}
	err = scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
		var wishlistID int64
		var item wishlistItem
		cols["wishlist_id"], cols["product_id"], cols["variant_id"] = &wishlistID, &item.productID, &item.variant
		cols["recurrence"], cols["rent"], cols["quantity"] = &item.recurrence, &item.rent, &item.quantity
		return func() { byID[wishlistID].items = append(byID[wishlistID].items, item) }
	}, "SELECT `wishlist_products`.* FROM `wishlist_products` WHERE `wishlist_products`.`deleted_at` IS NULL"+
		" AND `wishlist_products`.`wishlist_id` IN ("+placeholders(len(ids))+")", int64Args(ids)...)
	return lists, err
}

// scanNamed is db.ScanNamed.
func scanNamed(ctx context.Context, conn *sql.DB, bind func(cols map[string]any) func(), query string, args ...any) error {
	return db.ScanNamed(ctx, conn, bind, query, args...)
}

// viewerWishlists is product_props' wishlists: each of pundit_user.seller's wishlists, with what it
// holds of the product.
func (h *handler) viewerWishlists(p *page, prod *product) []any {
	out := []any{}
	if p.currentSeller == nil {
		return out
	}
	for _, w := range p.currentSeller.wishlists {
		selections := []any{}
		for _, it := range w.items {
			if it.productID != prod.id {
				continue
			}
			var variantID, rent any
			if it.variant.Valid {
				variantID = h.c.IDs.Encrypt(it.variant.Int64)
			}
			if it.rent.Valid {
				rent = it.rent.Bool
			}
			selections = append(selections, rails.NewRHash().Sym("variant_id", variantID).Sym("recurrence", nullString(it.recurrence)).
				Sym("rent", rent).Sym("quantity", nullInt(it.quantity)))
		}
		out = append(out, rails.NewRHash().Sym("id", h.c.IDs.Encrypt(w.id)).Sym("name", nullString(w.name)).
			Sym("selections_in_wishlist", selections))
	}
	return out
}
