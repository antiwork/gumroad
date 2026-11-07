package products

import (
	"database/sql"
	"slices"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

const (
	profileWishlistsSectionType = "SellerProfileWishlistsSection"
	// wishlistCardThumbnails is how many of a wishlist's last products card_props shows.
	wishlistCardThumbnails = 4
)

// shownWishlists is a wishlists section's shown_wishlists, which cached_sections maps over.
func shownWishlists(j jsonData) ([]int64, error) {
	list, ok := j.get("shown_wishlists").([]any)
	if !ok {
		return nil, fallback("product section json_data")
	}
	ids, ok := jsonIDs(list)
	if !ok {
		return nil, fallback("product section json_data")
	}
	return ids, nil
}

type wishlistRow struct {
	id, userID, followerCount int64
	name                      string
	description               sql.NullString
	// productIDs are its alive wishlist products', in the order the preload returns them.
	productIDs []int64
}

// wishlistCards is section_props' wishlists: WishlistPresenter.cards_props over the alive
// shown wishlists, in shown_wishlists order.
func (h *handler) wishlistCards(p *page, shown []int64) ([]any, error) {
	out := []any{}
	if len(shown) == 0 {
		return out, nil
	}
	ctx := p.Ctx
	rows, err := h.c.DB.QueryContext(ctx, "SELECT wishlists.id, wishlists.user_id, wishlists.name, wishlists.description,"+
		" wishlists.follower_count FROM wishlists WHERE wishlists.deleted_at IS NULL AND wishlists.id IN ("+placeholders(len(shown))+")",
		int64Args(shown)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var wishlists []*wishlistRow
	byID := map[int64]*wishlistRow{}
	var userIDs []int64
	for rows.Next() {
		w := &wishlistRow{}
		if err := rows.Scan(&w.id, &w.userID, &w.name, &w.description, &w.followerCount); err != nil {
			return nil, err
		}
		wishlists = append(wishlists, w)
		byID[w.id] = w
		if !slices.Contains(userIDs, w.userID) {
			userIDs = append(userIDs, w.userID)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	rows.Close()
	if len(wishlists) == 0 {
		return out, nil
	}
	ids := make([]int64, len(wishlists))
	for i, w := range wishlists {
		ids[i] = w.id
	}

	users, err := h.wishlistUsers(p, userIDs)
	if err != nil {
		return nil, err
	}
	// The preload has no ORDER BY; the wishlist_id index returns each wishlist's rows by id.
	rows, err = h.c.DB.QueryContext(ctx, "SELECT wishlist_products.wishlist_id, wishlist_products.product_id FROM wishlist_products"+
		" WHERE wishlist_products.deleted_at IS NULL AND wishlist_products.wishlist_id IN ("+placeholders(len(ids))+")"+
		" ORDER BY wishlist_products.wishlist_id, wishlist_products.id", int64Args(ids)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var wishlistID, productID int64
		if err := rows.Scan(&wishlistID, &productID); err != nil {
			return nil, err
		}
		w := byID[wishlistID]
		w.productIDs = append(w.productIDs, productID)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	rows.Close()

	thumbnails, err := h.wishlistThumbnails(p, wishlists)
	if err != nil {
		return nil, err
	}
	following := map[int64]bool{}
	// Following and can_follow are pundit_user.seller's.
	if p.currentSeller != nil {
		rows, err := h.c.DB.QueryContext(ctx, "SELECT wishlist_followers.wishlist_id FROM wishlist_followers"+
			" WHERE wishlist_followers.deleted_at IS NULL AND wishlist_followers.follower_user_id = ?"+
			" AND wishlist_followers.wishlist_id IN ("+placeholders(len(ids))+")", append([]any{p.currentSeller.id}, int64Args(ids)...)...)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		for rows.Next() {
			var id int64
			if err := rows.Scan(&id); err != nil {
				return nil, err
			}
			following[id] = true
		}
		if err := rows.Err(); err != nil {
			return nil, err
		}
	}

	slices.SortFunc(wishlists, func(a, b *wishlistRow) int { return slices.Index(shown, a.id) - slices.Index(shown, b.id) })
	for _, w := range wishlists {
		u := users[w.userID]
		numeric, ok := h.c.IDs.EncryptNumeric(w.id)
		if !ok {
			return nil, fallback("wishlist id")
		}
		profileURL := h.userProfileURL(u.user)
		last := w.productIDs[max(0, len(w.productIDs)-wishlistCardThumbnails):]
		shownThumbnails := make([]any, len(last))
		for i, id := range last {
			shownThumbnails[i] = thumbnails[id]
		}
		if len(shownThumbnails) < wishlistCardThumbnails && len(shownThumbnails) > 0 {
			shownThumbnails = shownThumbnails[len(shownThumbnails)-1:]
		}
		out = append(out, rails.NewRHash().
			Sym("id", h.c.IDs.Encrypt(w.id)).
			Sym("url", profileURL+"/wishlists/"+rails.Parameterize(w.name)+"-"+itoa(numeric)+"?layout=profile").
			Sym("name", w.name).
			Sym("description", nullString(w.description)).
			Sym("seller", bylineProps(u.user, u.avatarURL, profileURL)).
			Sym("thumbnails", shownThumbnails).
			Sym("product_count", int64(len(w.productIDs))).
			Sym("follower_count", w.followerCount).
			Sym("following", following[w.id]).
			Sym("can_follow", p.currentSeller == nil || p.currentSeller.id != w.userID))
	}
	return out, nil
}

type wishlistUser struct {
	user      *user
	avatarURL string
}

// wishlistUsers is each card's wishlist.user, with its avatar.
func (h *handler) wishlistUsers(p *page, ids []int64) (map[int64]wishlistUser, error) {
	rows, err := h.c.DB.QueryContext(p.Ctx, "SELECT "+userColumns+" FROM users WHERE users.id IN ("+placeholders(len(ids))+")", int64Args(ids)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	users := map[int64]wishlistUser{}
	for rows.Next() {
		u := &user{}
		if err := rows.Scan(u.dest()...); err != nil {
			return nil, err
		}
		users[u.id] = wishlistUser{user: u}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	rows.Close()
	for _, id := range ids {
		wu, ok := users[id]
		if !ok {
			return nil, fallback("wishlist user")
		}
		if wu.avatarURL, err = h.avatarURL(p, id); err != nil {
			return nil, err
		}
		users[id] = wu
	}
	return users, nil
}

// wishlistThumbnails is product_thumbnail for each product among the wishlists' last four.
func (h *handler) wishlistThumbnails(p *page, wishlists []*wishlistRow) (map[int64]any, error) {
	var ids []int64
	for _, w := range wishlists {
		for _, id := range w.productIDs[max(0, len(w.productIDs)-wishlistCardThumbnails):] {
			if !slices.Contains(ids, id) {
				ids = append(ids, id)
			}
		}
	}
	out := map[int64]any{}
	if len(ids) == 0 {
		return out, nil
	}
	nativeTypes := map[int64]sql.NullString{}
	rows, err := h.c.DB.QueryContext(p.Ctx, "SELECT links.id, links.native_type FROM links WHERE links.id IN ("+placeholders(len(ids))+")",
		int64Args(ids)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id int64
		var nativeType sql.NullString
		if err := rows.Scan(&id, &nativeType); err != nil {
			return nil, err
		}
		nativeTypes[id] = nativeType
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	rows.Close()
	thumbnails, err := h.aliveThumbnails(p.Ctx, ids)
	if err != nil {
		return nil, err
	}
	cards := make([]*card, len(ids))
	for i, id := range ids {
		if _, ok := nativeTypes[id]; !ok {
			return nil, fallback("wishlist product")
		}
		cards[i] = &card{prod: &product{id: id}, thumbnail: thumbnails[id]}
	}
	if err := h.cardThumbnails(p, cards); err != nil {
		return nil, err
	}
	for _, c := range cards {
		out[c.prod.id] = rails.NewRHash().Sym("url", c.thumbnailURL).Sym("native_type", nullString(nativeTypes[c.prod.id]))
	}
	return out, nil
}
