package products

import (
	"context"
	"slices"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// freeTrialReminderDays is Subscription::FREE_TRIAL_EXPIRING_REMINDER_EMAIL in days.
const freeTrialReminderDays int64 = 2

// recurrence is a BasePrice::Recurrence, with its months and renewal_reminder_lead_days.
type recurrence struct {
	name         string
	months       int
	reminderDays []any
}

// allRecurrences is BasePrice::Recurrence.all.
var allRecurrences = []recurrence{
	{"monthly", 1, []any{int64(1)}},
	{"quarterly", 3, []any{int64(7)}},
	{"biannually", 6, []any{int64(7)}},
	{"yearly", 12, []any{int64(30), int64(7)}},
	{"every_two_years", 24, []any{int64(30), int64(7)}},
}

// unportedMembership is a membership or free-trial shape this port leaves to Rails.
func unportedMembership(prod *product) string {
	recurring, tiered := prod.is(productIsRecurringBilling), prod.is(productIsTieredMembership)
	duration, durationOK := prod.subscriptionDurationName()
	_, unitOK := prod.freeTrialUnitName()
	switch {
	case tiered && !recurring:
		return "tiers without recurring billing"
	case tiered && prod.is(productSkusEnabled):
		return "tiered skus"
	case recurring && !durationOK:
		return "subscription duration"
	case recurring && duration == "":
		// is_default_recurrence? would match a recurrence of "".
		return "no subscription duration"
	case recurring && prod.purchaseType.Int64 != purchaseTypeBuyOnly:
		return "membership rental"
	case prod.is(productFreeTrialEnabled) && !unitOK:
		return "free trial unit"
	}
	return ""
}

// recurrenceNamed is the BasePrice::Recurrence of that name.
func recurrenceNamed(name string) (recurrence, bool) {
	i := slices.IndexFunc(allRecurrences, func(r recurrence) bool { return r.name == name })
	if i < 0 {
		return recurrence{}, false
	}
	return allRecurrences[i], true
}

// hasDefaultRecurrence is whether default_price_recurrence finds any alive price at the
// subscription duration, rentals included.
func hasDefaultRecurrence(rows []priceRow, duration string) bool {
	return slices.ContainsFunc(rows, func(r priceRow) bool { return r.recurrence.Valid && r.recurrence.String == duration })
}

// tierRecurrences is the recurrences Link#recurrence_price_enabled? finds an alive buy price
// at, in any currency. Each tier reaches the product afresh, so Rails asks MySQL, under the
// column's collation; a recurrence that isn't exactly one of the names goes to Rails.
func tierRecurrences(ps prices) (map[string]bool, error) {
	out := map[string]bool{}
	for _, r := range ps.rows {
		if r.isRental() || !r.recurrence.Valid {
			continue
		}
		if _, ok := recurrenceNamed(r.recurrence.String); !ok {
			return nil, fallback("price recurrence")
		}
		out[r.recurrence.String] = true
	}
	return out, nil
}

// recurrences is Link#recurrences; nil is nil.
type recurrences struct {
	def       string
	enabled   []any
	trialDays any
}

func (r *recurrences) props() any {
	if r == nil {
		return nil
	}
	return rails.NewRHash().Sym("default", r.def).Sym("enabled", r.enabled).Sym("free_trial_reminder_days", r.trialDays)
}

// defaultRecurrence is recurrences&.dig(:default).
func (r *recurrences) defaultRecurrence() any {
	if r == nil {
		return nil
	}
	return r.def
}

func (h *handler) loadRecurrences(ctx context.Context, prod *product, ps prices) (*recurrences, error) {
	if !prod.is(productIsRecurringBilling) {
		return nil, nil
	}
	type enabledPrice struct {
		row          priceRow
		months       int
		reminderDays []any
	}
	var enabled []enabledPrice
	for _, r := range ps.rows {
		if r.isRental() || !r.recurrence.Valid {
			continue
		}
		if rec, ok := recurrenceNamed(r.recurrence.String); ok {
			enabled = append(enabled, enabledPrice{r, rec.months, rec.reminderDays})
		}
	}
	for i := range enabled {
		for j := range i {
			if enabled[i].months == enabled[j].months {
				// sort_by isn't stable.
				return nil, fallback("recurrence tie")
			}
		}
	}
	slices.SortFunc(enabled, func(a, b enabledPrice) int { return a.months - b.months })

	out := &recurrences{}
	duration, _ := prod.subscriptionDurationName()
	if hasDefaultRecurrence(ps.rows, duration) {
		out.def = duration
	} else if len(enabled) > 0 {
		out.def = enabled[0].row.recurrence.String
	} else {
		return nil, nil
	}
	remindersOn := false
	if len(enabled) > 0 || prod.is(productFreeTrialEnabled) {
		var err error
		if remindersOn, err = h.flag(ctx, "membership_renewal_reminders", prod.userID); err != nil {
			return nil, err
		}
	}
	out.enabled = make([]any, 0, len(enabled))
	for _, e := range enabled {
		days := []any{}
		if remindersOn {
			days = e.reminderDays
		}
		out.enabled = append(out.enabled, rails.NewRHash().
			Sym("recurrence", e.row.recurrence.String).
			Sym("price_cents", e.row.cents).
			Sym("id", h.c.IDs.Encrypt(e.row.id)).
			Sym("renewal_reminder_days", days))
	}
	if remindersOn && prod.is(productFreeTrialEnabled) {
		out.trialDays = freeTrialReminderDays
	}
	return out, nil
}

// freeTrialProps is the free_trial prop.
func freeTrialProps(prod *product) any {
	if !prod.is(productFreeTrialEnabled) {
		return nil
	}
	var unit any
	if name, _ := prod.freeTrialUnitName(); name != "" {
		unit = name
	}
	return rails.NewRHash().Sym("duration", rails.NewRHash().Sym("unit", unit).Sym("amount", nullInt(prod.freeTrialDurationAmount)))
}

// lowestTierPriceCents is lowest_tier_price's price_cents: the cheapest alive buy price, in
// any currency, of the offered tiers, else 0. With for_default_duration, only the prices at
// the subscription duration count.
func lowestTierPriceCents(offered []*variantOption, duration *string) int64 {
	var lowest *int64
	for _, o := range offered {
		for i, p := range o.buyPrices {
			if duration == nil || p.recurrence.Valid && p.recurrence.String == *duration {
				lowest = lowerOf(lowest, &o.buyPrices[i].cents)
			}
		}
	}
	if lowest == nil {
		return 0
	}
	return *lowest
}

// offeredTiers is tiers_for_displayed_price: the tiers open to new buyers, or every tier
// when all are closed.
func offeredTiers(tiers []*variantOption) []*variantOption {
	open := slices.DeleteFunc(slices.Clone(tiers), func(o *variantOption) bool { return o.closed })
	if len(open) == 0 {
		return tiers
	}
	return open
}

// closedToNewBuyers is closed_membership_for_new_buyers?.
func (vs *variants) closedToNewBuyers(prod *product) bool {
	if !prod.is(productIsTieredMembership) || len(vs.tiers) == 0 {
		return false
	}
	return !slices.ContainsFunc(vs.tiers, (*variantOption).available)
}
