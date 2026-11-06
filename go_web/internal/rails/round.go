package rails

import "math"

// floatDig is Ruby's float_dig, DBL_DIG + 2.
const floatDig = 17

// RoundFloat is Float#round(digits) for 0 <= digits <= 14 (rb_float_round with Ruby's
// round_half_up): round(x * 10**digits), corrected where that product lost the half. A
// value too large to have digits past the point comes back as it is, and one too small to
// reach them is 0.
func RoundFloat(x float64, digits int) float64 {
	if x == 0 || math.IsNaN(x) || math.IsInf(x, 0) {
		return x
	}
	if digits == 0 {
		return math.Round(x)
	}
	_, binexp := math.Frexp(x)
	// float_round_overflow and float_round_underflow; C's / truncates toward zero, as Go's does.
	if binexp > 0 && digits >= floatDig-binexp/4 || binexp <= 0 && digits >= floatDig-(binexp/3-1) {
		return x
	}
	if binexp > 0 && digits < -(binexp/3+1) || binexp <= 0 && digits < -(binexp/4) {
		return 0
	}
	s := math.Pow(10, float64(digits))
	f := math.Round(x * s)
	if x > 0 {
		if (f+0.5)/s <= x {
			f++
		}
	} else if (f-0.5)/s >= x {
		f--
	}
	return f / s
}
