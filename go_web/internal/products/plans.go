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
	var installments int64
	var recurrence string
	n, err := h.scanFirst(ctx, []any{&installments, &recurrence}, "SELECT product_installment_plans.number_of_installments,"+
		" product_installment_plans.recurrence FROM product_installment_plans WHERE product_installment_plans.link_id = ?"+
		" AND product_installment_plans.deleted_at IS NULL LIMIT 2", prod.id)
	switch {
	case err != nil || n == 0:
		return nil, err
	case n > 1:
		return nil, fallback("several installment plans")
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
	var releaseAt db.NullTime
	n, err := h.scanFirst(ctx, []any{&releaseAt}, "SELECT preorder_links.release_at FROM preorder_links"+
		" WHERE preorder_links.link_id = ? LIMIT 2", prod.id)
	if err != nil {
		return nil, err
	}
	if n != 1 {
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
