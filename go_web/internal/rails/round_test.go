package rails

import "testing"

// Ruby 3.4's Float#round, including the halves binary floats can't hold exactly.
func TestRoundFloatIsRubys(t *testing.T) {
	for _, c := range []struct {
		x      float64
		digits int
		want   float64
	}{{4.85, 1, 4.9}, {4.45, 1, 4.5}, {2.675, 2, 2.68}, {1.005, 2, 1.01}, {0.05, 1, 0.1}, {4.95, 1, 5.0}, {3.25, 1, 3.3},
		{4.666666666666667, 1, 4.7}, {-2.5, 0, -3}, {19.99, 2, 19.99}} {
		if got := RoundFloat(c.x, c.digits); got != c.want {
			t.Errorf("%v.round(%d) = %v, want %v", c.x, c.digits, got, c.want)
		}
	}
}
