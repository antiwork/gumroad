package products

import (
	"math/big"
	"regexp"
	"strconv"
	"strings"
)

// plainDecimal is a rate String#to_f and strconv read alike.
var plainDecimal = regexp.MustCompile(`^[0-9]+(\.[0-9]+)?$`)

// formatJustPriceInCents is CurrencyHelper#format_just_price_in_cents: MoneyFormatter.format
// with no_cents_if_whole, and "99¢" for $0.99. ok is false for a currency the table lacks,
// which MoneyFormatter soft-fails on, and for a negative amount.
func formatJustPriceInCents(cents int64, currency string) (string, bool) {
	f, known := currencies[strings.ToLower(currency)]
	if !known || cents < 0 {
		return "", false
	}
	price := f.prefix + moneyNumber(cents, f.singleUnit) + f.suffix
	if price == "$0.99" {
		return "99¢", true
	}
	return price, true
}

func groupThousands(digits string) string {
	var b strings.Builder
	for i, c := range digits {
		if i > 0 && (len(digits)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(c)
	}
	return b.String()
}

// usdCentsToCurrency is CurrencyHelper#usd_cents_to_currency with the purchase's stored rate:
// BigDecimal(cents) times rate.to_f, rounded half up, after dividing by 100 for a currency
// without subunits. ok is false where Rails
// would look up a live rate, or read the rate other than strconv does.
func usdCentsToCurrency(currency string, cents int64, rate string) (int64, bool) {
	if currency == "usd" {
		return cents, true
	}
	f, known := currencies[strings.ToLower(currency)]
	if !known || !plainDecimal.MatchString(rate) {
		return 0, false
	}
	r, err := strconv.ParseFloat(rate, 64)
	if err != nil {
		return 0, false
	}
	operand, _ := new(big.Rat).SetString(bigDecimalFloat(r))
	x := new(big.Rat).Mul(big.NewRat(cents, 1), operand)
	if f.singleUnit {
		x.Quo(x, big.NewRat(100, 1))
	}
	return roundHalfUp(x, 0).Num().Int64(), true
}
