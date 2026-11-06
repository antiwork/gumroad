package products

import (
	"math/big"
	"regexp"
	"strconv"
	"strings"
)

// rubyDecimal is a decimal as BigDecimal holds it: the exact value and BigDecimal#precision.
type rubyDecimal struct {
	r    *big.Rat
	prec int
}

// strictDecimal is the String#to_d input read here; to_d accepts more (a trailing "abc",
// underscores), which Rails may read differently, so that goes to Rails.
var strictDecimal = regexp.MustCompile(`\A[ \t\n\v\f\r]*([+-]?)(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?\z`)

// parseRubyDecimal is String#to_d for strictDecimal input.
func parseRubyDecimal(s string) (rubyDecimal, bool) {
	m := strictDecimal.FindStringSubmatch(s)
	if m == nil {
		return rubyDecimal{}, false
	}
	exp := 0
	if m[4] != "" {
		e, err := strconv.Atoi(m[4])
		if err != nil || e > 400 || e < -400 {
			return rubyDecimal{}, false
		}
		exp = e
	}
	digits, frac := m[2]+m[3], len(m[3])-exp
	r, ok := new(big.Rat).SetString(m[1] + digits + "e" + strconv.Itoa(-frac))
	if !ok {
		return rubyDecimal{}, false
	}
	return rubyDecimal{r, decimalPrecision(digits, frac)}, true
}

// decimalPrecision is BigDecimal#precision of digits * 10**-frac: the integer part's digits
// plus the fraction's up to its last nonzero one, and for a value below 1 every fraction digit.
func decimalPrecision(digits string, frac int) int {
	digits = strings.TrimLeft(digits, "0")
	if digits == "" {
		return 0
	}
	intDigits := len(digits) - frac
	fraction := ""
	if frac > 0 {
		if intDigits > 0 {
			fraction = digits[intDigits:]
		} else {
			fraction = strings.Repeat("0", -intDigits) + digits
		}
	}
	fraction = strings.TrimRight(fraction, "0")
	if intDigits <= 0 {
		return len(fraction)
	}
	return intDigits + len(fraction)
}

// bigDecimalQuo is BigDecimal#/: the quotient rounded half up to
// max(32, max(a.prec, b.prec) + 16) significant digits.
func bigDecimalQuo(a, b rubyDecimal) *big.Rat {
	q := new(big.Rat).Quo(a.r, b.r)
	if q.Sign() == 0 {
		return q
	}
	return roundSignificant(q, max(32, max(a.prec, b.prec)+16))
}

// roundSignificant rounds a positive q half up to n significant digits.
func roundSignificant(q *big.Rat, n int) *big.Rat {
	// 10**(l-1) <= q < 10**(l+1) for l = len(num) - len(den), so one comparison settles it.
	e := len(q.Num().String()) - len(q.Denom().String())
	if q.Cmp(pow10Rat(e)) < 0 {
		e--
	}
	return roundHalfUp(q, n-1-e)
}

func pow10Rat(e int) *big.Rat {
	p := new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(abs(e))), nil)
	if e < 0 {
		return new(big.Rat).SetFrac(big.NewInt(1), p)
	}
	return new(big.Rat).SetInt(p)
}

// shortestRat is BigDecimal(float.to_s): the Float's shortest round-trip digits.
func shortestRat(f float64) *big.Rat {
	r, _ := new(big.Rat).SetString(strconv.FormatFloat(f, 'g', -1, 64))
	return r
}

// localPriceCents is buyer_local_price_cents: price in from's minor units, through rate, in
// to's, rounded half up.
func localPriceCents(price int64, from, to string, rate *big.Rat) int64 {
	x := new(big.Rat).SetFrac64(price, unitScalingFactor(from))
	x.Mul(x, rate)
	x.Mul(x, big.NewRat(unitScalingFactor(to), 1))
	return roundHalfUp(x, 0).Num().Int64()
}

// minorUnitRate is buyer_local_price_props' rate: BigDecimal(rate.to_s) * the buyer's subunit
// / the product's, back to a Float.
func minorUnitRate(rate float64, product, buyer string) float64 {
	x := shortestRat(rate)
	x.Mul(x, big.NewRat(unitScalingFactor(buyer), unitScalingFactor(product)))
	f, _ := x.Float64()
	return f
}
