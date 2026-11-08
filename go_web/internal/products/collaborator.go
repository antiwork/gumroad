package products

import (
	"context"
	"database/sql"

	"github.com/antiwork/gumroad/go_web/internal/rails"
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
	// confirmed_collaborators.alive.take's statement, verbatim: it has no ORDER BY, so MySQL's plan
	// picks the row, the same one for both of collaborator_for_display's reads.
	var affiliateID, flags int64
	var userID sql.NullInt64
	found := false
	if err := scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
		cols["id"], cols["flags"], cols["affiliate_user_id"] = &affiliateID, &flags, &userID
		return func() { found = true }
	}, "SELECT `affiliates`.`id`, `affiliates`.`seller_id`, `affiliates`.`affiliate_user_id`, `affiliates`.`affiliate_basis_points`,"+
		" `affiliates`.`created_at`, `affiliates`.`updated_at`, `affiliates`.`deleted_at`, `affiliates`.`flags`, `affiliates`.`destination_url`,"+
		" `affiliates`.`type` FROM `affiliates` INNER JOIN `affiliates_links` ON `affiliates`.`id` = `affiliates_links`.`affiliate_id`"+
		" LEFT OUTER JOIN `collaborator_invitations` ON `collaborator_invitations`.`collaborator_id` = `affiliates`.`id`"+
		" WHERE `affiliates_links`.`link_id` = ? AND `affiliates`.`type` = 'Collaborator' AND `collaborator_invitations`.`id` IS NULL"+
		" AND `affiliates`.`deleted_at` IS NULL LIMIT 1", prod.id); err != nil || !found {
		return nil, err
	}
	// show_as_co_creator_for_product?: the collaborator-wide flag, else product_affiliates.find_by's.
	show := flags&affiliateDontShowAsCoCreator == 0
	if flags&affiliateApplyToAllProducts == 0 {
		var linkFlags int64
		err := h.c.DB.QueryRowContext(ctx, "SELECT `affiliates_links`.`flags` FROM `affiliates_links` WHERE `affiliates_links`.`affiliate_id` = ?"+
			" AND `affiliates_links`.`link_id` = ? LIMIT 1", affiliateID, prod.id).Scan(&linkFlags)
		if err != nil {
			return nil, err
		}
		show = linkFlags&productAffiliateDontShow == 0
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
	avatar, err := h.avatarURL(p, u.id)
	if err != nil {
		return nil, err
	}
	return bylineProps(u, avatar, h.userProfileURL(u)), nil
}
