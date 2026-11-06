package products

import (
	"context"
	"errors"

	"github.com/antiwork/gumroad/go_web/internal/description"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// loadDescription is html_safe_description, plaintext_description and the structured data's
// product_description.
func (h *handler) loadDescription(ctx context.Context, prod *product, v *view) error {
	cfg := description.Config{
		CDNMap:   h.c.Page.CDNMap,
		Protocol: h.c.Env.Protocol,
		ReviewExists: func(externalID string) (bool, error) {
			id, ok := h.c.IDs.Decrypt(externalID)
			if !ok {
				return false, nil
			}
			return h.exists(ctx, "SELECT 1 FROM product_reviews WHERE product_reviews.link_id = ? AND product_reviews.id = ? LIMIT 1", prod.id, id)
		},
	}
	both := description.HTMLAndPlaintext(prod.description.String, cfg)
	if err := firstErr(both.HTMLErr, both.PlaintextErr); err != nil {
		return unportedDescription(err)
	}
	present, html := both.Present, both.HTML
	v.descriptionPresent = present
	if present {
		v.descriptionHTML = html
		v.plaintextDescription = both.Plaintext
	}
	summary := v.productJSON.get("custom_summary")
	var text string
	switch {
	case rails.Present(summary):
		s, ok := summary.(string)
		if !ok {
			return fallback("custom summary")
		}
		text = description.Squish(s)
	case present:
		var err error
		if text, err = description.StripTagsSquished(html); err != nil {
			return unportedDescription(err)
		}
	}
	if s := description.Snippet(text); s != "" {
		v.structuredDescription = &s
	}
	return nil
}

func unportedDescription(err error) error {
	if errors.Is(err, description.ErrUnported) {
		return fallback("description")
	}
	return err
}
