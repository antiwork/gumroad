package products

import (
	"context"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// installmentPlanProps is the installment_plan prop: Link#installment_plan, alive.
func (h *handler) installmentPlanProps(ctx context.Context, p *page, prod *product) (any, error) {
	if !p.hasInstallmentPlan {
		return nil, nil
	}
	// The has_one's statement, verbatim: it has no ORDER BY, so MySQL's plan picks the row.
	var installments int64
	var recurrence string
	found := false
	if err := scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
		cols["number_of_installments"], cols["recurrence"] = &installments, &recurrence
		return func() { found = true }
	}, "SELECT `product_installment_plans`.* FROM `product_installment_plans` WHERE `product_installment_plans`.`link_id` = ?"+
		" AND `product_installment_plans`.`deleted_at` IS NULL LIMIT 1", prod.id); err != nil || !found {
		return nil, err
	}
	// The enum maps only monthly, and reads any other value as nil.
	var shown any
	if recurrence == "monthly" {
		shown = recurrence
	}
	return rails.NewRHash().Sym("number_of_installments", installments).Sym("recurrence", shown), nil
}

// preorderProps is the preorder prop, from Link#preorder_link.
func (h *handler) preorderProps(ctx context.Context, prod *product) (any, error) {
	if !prod.is(productIsInPreorderState) {
		return nil, nil
	}
	// The has_one's statement, verbatim: it has no ORDER BY, so MySQL's plan picks the row.
	var releaseAt db.NullTime
	found := false
	if err := scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
		cols["release_at"] = &releaseAt
		return func() { found = true }
	}, "SELECT `preorder_links`.* FROM `preorder_links` WHERE `preorder_links`.`link_id` = ? LIMIT 1", prod.id); err != nil {
		return nil, err
	}
	if !found {
		// Without one Rails raises.
		return nil, fallback("preorder link")
	}
	return rails.NewRHash().Sym("release_date", releaseAt.OrNil()), nil
}

// waitlistProps is waitlist_props; only the seller sees the count.
func (h *handler) waitlistProps(prod *product, v *view) any {
	if !prod.acceptsWaitlistSignups() {
		return nil
	}
	return rails.NewRHash().Sym("recaptcha_site_key", v.recaptchaSiteKey).Sym("count", v.waitlistCount)
}
