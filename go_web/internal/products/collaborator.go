package products

import (
	"context"
	"database/sql"
	"errors"

	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/storage"
)

// Affiliate and ProductAffiliate flag bits (has_flags).
const (
	affiliateApplyToAllProducts  int64 = 1 << 0
	affiliateDontShowAsCoCreator int64 = 1 << 2
	productAffiliateDontShow     int64 = 1 << 0
)

// collaboratorByline is the collaborating_user prop: Link#collaborator_for_display, the
// confirmed Collaborator's user when it shows as co-creator, as author_byline_props.
// unportedShape's batch tells whether the product has any Collaborator row.
func (h *handler) collaboratorByline(ctx context.Context, p *page, prod *product) (any, error) {
	if !p.hasCollaborator {
		return nil, nil
	}
	var flags, linkFlags int64
	var userID sql.NullInt64
	n, err := h.scanFirst(ctx, []any{&flags, &userID, &linkFlags}, "SELECT affiliates.flags, affiliates.affiliate_user_id, affiliates_links.flags"+
		" FROM affiliates INNER JOIN affiliates_links ON affiliates.id = affiliates_links.affiliate_id"+
		" WHERE affiliates_links.link_id = ? AND affiliates.type = 'Collaborator' AND affiliates.deleted_at IS NULL"+
		" AND NOT EXISTS (SELECT 1 FROM collaborator_invitations WHERE collaborator_invitations.collaborator_id = affiliates.id)"+
		" LIMIT 2", prod.id)
	if err != nil {
		return nil, err
	}
	switch {
	case n == 0:
		return nil, nil
	case n > 1:
		// confirmed_collaborators.alive.take has no order.
		return nil, fallback("several collaborators")
	}
	// show_as_co_creator_for_product?: the collaborator-wide flag wins over the product's.
	show := linkFlags&productAffiliateDontShow == 0
	if flags&affiliateApplyToAllProducts != 0 {
		show = flags&affiliateDontShowAsCoCreator == 0
	}
	if !show || !userID.Valid {
		return nil, nil
	}
	u, err := userByID(ctx, h.c.DB, userID.Int64)
	if u == nil || err != nil {
		return nil, err
	}
	// author_byline_props returns before avatar_url for a user without a username.
	if rails.Blank(sellerUsername(u)) {
		return nil, nil
	}
	avatar, err := h.c.Page.Avatars.URL(ctx, u.id)
	if errors.Is(err, storage.ErrUnported) {
		return nil, fallback("collaborator avatar")
	}
	if err != nil {
		return nil, err
	}
	return bylineProps(u, avatar, h.userProfileURL(u)), nil
}
