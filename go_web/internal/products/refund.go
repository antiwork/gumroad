package products

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/description"
	"github.com/antiwork/gumroad/go_web/internal/html4"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// refundPeriodTitles is RefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS.
var refundPeriodTitles = map[int64]string{
	0: "No refunds allowed", 7: "7-day money back guarantee", 14: "14-day money back guarantee",
	30: "30-day money back guarantee", 183: "6-month money back guarantee",
}

// loadRefundPolicy is refund_policy_props for the product's own policy; the seller's
// account-level one is Rails' (unportedShape).
func (h *handler) loadRefundPolicy(ctx context.Context, prod *product) (any, error) {
	if !prod.is(productRefundPolicyEnabled) {
		return nil, nil
	}
	var period sql.NullInt64
	var finePrint sql.NullString
	var updatedAt db.NullTime
	err := h.c.DB.QueryRowContext(ctx, "SELECT refund_policies.max_refund_period_in_days, refund_policies.fine_print,"+
		" refund_policies.updated_at FROM refund_policies WHERE refund_policies.product_id = ? LIMIT 1", prod.id).
		Scan(&period, &finePrint, &updatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		// The flag can outlive the row.
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if !updatedAt.Valid {
		return nil, fallback("refund policy updated_at")
	}
	var title any
	if t, ok := refundPeriodTitles[period.Int64]; ok && period.Valid {
		title = t
	}
	var fine any
	if rails.Present(finePrint.String) {
		formatted, err := simpleFormat(finePrint.String)
		if err != nil {
			return nil, err
		}
		fine = formatted
	}
	return rails.NewRHash().
		Sym("title", title).
		Sym("fine_print", fine).
		Sym("updated_at", updatedAt.Time.UTC().Format(time.DateOnly)), nil
}

// simpleFormat is simple_format(text) for text without markup, which RefundPolicy's
// strip_tags leaves: the HTML4 sanitizer only re-serializes it.
func simpleFormat(text string) (string, error) {
	if strings.Contains(text, "<") {
		return "", fallback("refund policy markup")
	}
	frag, err := html4.ParseFragment(text)
	if errors.Is(err, html4.ErrUnported) {
		return "", fallback("refund policy text")
	}
	if err != nil {
		return "", err
	}
	return description.Paragraphs(frag.RenderChildren()), nil
}
