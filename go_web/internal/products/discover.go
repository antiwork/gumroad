package products

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/flipper"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/railscache"
)

// recordsDiscoverSearch is whether create_discover_search! writes the click: a recommendation
// from Discover's search, not a bot, with store_discover_searches on for the browser.
func (h *handler) recordsDiscoverSearch(p *page) (bool, error) {
	if p.recommendedBy == nil || (*p.recommendedBy != "search" && *p.recommendedBy != "discover") || rails.IsBot(p.Req) {
		return false, nil
	}
	if p.GUID == "" {
		// Flipper rolls a blank flipper_id as an actor; the Go flipper reads it as none.
		return false, fallback("blank guid")
	}
	on, err := h.c.Page.Flag("store_discover_searches").ActiveFor(p.Ctx, p.GUID)
	if errors.Is(err, flipper.ErrUnevaluable) {
		return false, fallback("flag store_discover_searches")
	}
	return on, err
}

// productTaxonomyID is the product's taxonomy_id, read before anything is written.
func (h *handler) productTaxonomyID(ctx context.Context, prod *product) (sql.NullInt64, error) {
	var id sql.NullInt64
	err := h.c.DB.QueryRowContext(ctx, "SELECT links.taxonomy_id FROM links WHERE links.id = ?", prod.id).Scan(&id)
	return id, err
}

// createDiscoverSearch is DiscoverSearch.create! for the clicked product. Without a query, which
// is a declined param, there's no suggestion to create.
func (h *handler) createDiscoverSearch(ctx context.Context, p *page, prod *product, ip string, taxonomyID sql.NullInt64) error {
	var userID any
	if p.viewer != nil {
		userID = p.viewer.id
	}
	now := p.Req.Now.UTC().Truncate(time.Microsecond)
	_, err := h.c.DB.ExecContext(context.WithoutCancel(ctx), "INSERT INTO discover_searches (query, taxonomy_id, user_id, ip_address,"+
		" browser_guid, autocomplete, created_at, updated_at, clicked_resource_type, clicked_resource_id)"+
		" VALUES (NULL, ?, ?, ?, ?, FALSE, ?, ?, 'Link', ?)", taxonomyID, userID, ip, p.GUID, now, now, prod.id)
	return err
}

// discoverNav is show's discover_props: the product's taxonomy path and taxonomies_for_nav.
// The nav is Rails.cache's list, reordered by RecommendedProducts::DiscoverService's picks, which
// a visitor's purchases or cart seed and it samples at random; only an unseeded one is ported.
func (h *handler) discoverNav(p *page, prod *product) (any, []any, error) {
	ctx := p.Ctx
	if p.viewer != nil {
		return nil, nil, fallback("discover recommendations")
	}
	cached, found, err := h.readCache(ctx, "taxonomies_for_nav")
	if err != nil {
		return nil, nil, err
	}
	// Rebuilding it on a miss would mean Ruby's unstable sort_by on its tied keys.
	list, ok := cached.([]any)
	if !found || !ok {
		return nil, nil, fallback("taxonomies for nav")
	}
	// Cart.fetch_by(user: nil, browser_guid:)'s alive products; any guest cart's count here.
	seeded, err := h.exists(ctx, "SELECT 1 FROM carts INNER JOIN cart_products ON cart_products.cart_id = carts.id"+
		" WHERE carts.browser_guid = ? AND carts.user_id IS NULL AND carts.deleted_at IS NULL AND cart_products.deleted_at IS NULL LIMIT 1", p.GUID)
	if err != nil || seeded {
		return nil, nil, firstErr(err, fallback("discover recommendations"))
	}
	nav := make([]any, len(list))
	for i, entry := range list {
		hash, ok := entry.(railscache.Hash)
		if !ok {
			return nil, nil, fallback("taxonomies for nav")
		}
		props := rails.NewRHash()
		for _, pair := range hash {
			key, isSymbol := pair.Key.(railscache.Symbol)
			value, isString := rubyString(pair.Value)
			switch {
			case !isSymbol:
				return nil, nil, fallback("taxonomies for nav")
			case isString:
				props.Sym(string(key), value)
			case pair.Value == nil:
				props.Sym(string(key), nil)
			default:
				return nil, nil, fallback("taxonomies for nav")
			}
		}
		nav[i] = props
	}

	// taxonomy&.ancestry_path&.join("/"): closure_tree's self_and_ancestors, root first, or nil
	// for a taxonomy that's gone.
	taxonomyID, err := h.productTaxonomyID(ctx, prod)
	if err != nil {
		return nil, nil, err
	}
	if !taxonomyID.Valid {
		return nil, nav, nil
	}
	if found, err := h.exists(ctx, "SELECT 1 FROM taxonomies WHERE taxonomies.id = ?", taxonomyID.Int64); err != nil || !found {
		return nil, nav, err
	}
	rows, err := h.c.DB.QueryContext(ctx, "SELECT taxonomies.slug FROM taxonomy_hierarchies INNER JOIN taxonomies"+
		" ON taxonomies.id = taxonomy_hierarchies.ancestor_id WHERE taxonomy_hierarchies.descendant_id = ?"+
		" ORDER BY taxonomy_hierarchies.generations DESC", taxonomyID.Int64)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	var slugs []string
	for rows.Next() {
		var slug sql.NullString
		if err := rows.Scan(&slug); err != nil {
			return nil, nil, err
		}
		slugs = append(slugs, slug.String)
	}
	if err := rows.Err(); err != nil {
		return nil, nil, err
	}
	return strings.Join(slugs, "/"), nav, nil
}
