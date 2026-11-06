package products

import (
	"context"
	"database/sql"
	"errors"
	"slices"
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

// createDiscoverSearch is create_discover_search! for the clicked product. A typed query's
// suggestion shares the search's transaction.
func (h *handler) createDiscoverSearch(ctx context.Context, p *page, prod *product, ip string, taxonomyID sql.NullInt64) error {
	ctx = context.WithoutCancel(ctx)
	var userID any
	if p.viewer != nil {
		userID = p.viewer.id
	}
	autocomplete := p.Req.Param("autocomplete") == "true"
	now := p.Req.Now.UTC().Truncate(time.Microsecond)
	const insert = "INSERT INTO discover_searches (query, taxonomy_id, user_id, ip_address, browser_guid, autocomplete," +
		" created_at, updated_at, clicked_resource_type, clicked_resource_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'Link', ?)"
	args := []any{p.query, taxonomyID, userID, ip, p.GUID, autocomplete, now, now, prod.id}
	if !rails.Present(p.query) || autocomplete {
		_, err := h.c.DB.ExecContext(ctx, insert, args...)
		return err
	}
	tx, err := h.c.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, insert, args...)
	if err != nil {
		return err
	}
	id, err := result.LastInsertId()
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, "INSERT INTO discover_search_suggestions (discover_search_id, created_at, updated_at)"+
		" VALUES (?, ?, ?)", id, now, now); err != nil {
		return err
	}
	return tx.Commit()
}

// discoverNav is show's discover_props: the product's taxonomy path and taxonomies_for_nav,
// Rails.cache's list reordered by curated_products.
func (h *handler) discoverNav(p *page, prod *product) (any, []any, error) {
	ctx := p.Ctx
	cached, found, err := h.readCache(ctx, "taxonomies_for_nav")
	if err != nil {
		return nil, nil, err
	}
	// Rebuilding it on a miss would mean Ruby's unstable sort_by on its tied keys.
	list, ok := cached.([]any)
	if !found || !ok {
		return nil, nil, fallback("taxonomies for nav")
	}
	entries := make([]*rails.RHash, len(list))
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
		entries[i] = props
	}
	curated, err := h.curatedTaxonomyIDs(p)
	if err != nil {
		return nil, nil, err
	}
	if err := h.sortNav(ctx, entries, curated); err != nil {
		return nil, nil, err
	}
	nav := make([]any, len(entries))
	for i, e := range entries {
		nav[i] = e
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
	var path []string
	for rows.Next() {
		var slug sql.NullString
		if err := rows.Scan(&slug); err != nil {
			return nil, nil, err
		}
		path = append(path, slug.String)
	}
	if err := rows.Err(); err != nil {
		return nil, nil, err
	}
	return strings.Join(path, "/"), nav, nil
}

// sortNav is taxonomies_for_nav's stable sort that brings the curated products' root taxonomies
// first, the root of the earliest product first.
func (h *handler) sortNav(ctx context.Context, nav []*rails.RHash, taxonomyIDs []int64) error {
	if len(taxonomyIDs) == 0 {
		return nil
	}
	ids := union(taxonomyIDs, nil)
	type root struct {
		slug         string
		rows         int
		withoutRoots bool
	}
	roots := map[int64]*root{}
	// find(taxonomy_ids) through a LEFT JOIN that a taxonomy without a root still matches.
	err := scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
		var id int64
		var rootID sql.NullInt64
		var slug sql.NullString
		cols["id"], cols["root_id"], cols["root_slug"] = &id, &rootID, &slug
		return func() {
			r := roots[id]
			if r == nil {
				r = &root{}
				roots[id] = r
			}
			r.rows++
			r.slug = slug.String
			r.withoutRoots = r.withoutRoots || !rootID.Valid || !slug.Valid
		}
	}, "SELECT taxonomies.id, roots.id AS root_id, roots.slug AS root_slug FROM taxonomies"+
		" LEFT OUTER JOIN taxonomy_hierarchies ON taxonomy_hierarchies.descendant_id = taxonomies.id"+
		" LEFT OUTER JOIN taxonomies roots ON roots.id = taxonomy_hierarchies.ancestor_id"+
		" WHERE roots.parent_id IS NULL AND taxonomies.id IN ("+placeholders(len(ids))+")", int64Args(ids)...)
	if err != nil {
		return err
	}
	scores := map[string]int{}
	for index, id := range ids {
		r := roots[id]
		switch {
		case r == nil:
			// find raises RecordNotFound.
			return fallback("curated taxonomy")
		case r.rows != 1 || r.withoutRoots:
			return fallback("curated taxonomy root")
		}
		if _, ok := scores[r.slug]; !ok {
			scores[r.slug] = len(taxonomyIDs) - index
		}
	}
	score := make(map[*rails.RHash]int, len(nav))
	for _, entry := range nav {
		if slug, ok := entry.Get("slug").(string); ok {
			score[entry] = scores[slug]
		}
	}
	slices.SortStableFunc(nav, func(a, b *rails.RHash) int { return score[b] - score[a] })
	return nil
}
