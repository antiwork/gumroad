package rails

import (
	"math"
	"testing"
)

// Ruby 3.4's Float#round, including the halves binary floats can't hold exactly.
func TestRoundFloatIsRubys(t *testing.T) {
	for _, c := range []struct {
		x      float64
		digits int
		want   float64
	}{{4.85, 1, 4.9}, {4.45, 1, 4.5}, {2.675, 2, 2.68}, {1.005, 2, 1.01}, {0.05, 1, 0.1}, {4.95, 1, 5.0}, {3.25, 1, 3.3},
		{4.666666666666667, 1, 4.7}, {-2.5, 0, -3}, {19.99, 2, 19.99},
		// Past 2**52 every float is an integer, which neither digits nor the correction change.
		{4503599627370496, 0, 4503599627370496}, {-4503599627370496, 0, -4503599627370496},
		{4503599627370496, 1, 4503599627370496}, {-4503599627370497, 2, -4503599627370497}, {1e300, 2, 1e300},
		{math.MaxFloat64, 1, math.MaxFloat64}, {-1e-20, 2, 0}} {
		// Ruby's underflow is +0.0 for either sign.
		if got := RoundFloat(c.x, c.digits); got != c.want || got == 0 && math.Signbit(got) != math.Signbit(c.want) {
			t.Errorf("%v.round(%d) = %v, want %v", c.x, c.digits, got, c.want)
		}
	}
}
