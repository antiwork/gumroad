package rails

import "math"

// RoundFloat is Float#round(digits) for 0 <= digits <= 14 and values far from overflow,
// Ruby's round_half_up: round(x * 10**digits), corrected where that product lost the half.
func RoundFloat(x float64, digits int) float64 {
	if x == 0 || math.IsNaN(x) || math.IsInf(x, 0) {
		return x
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
