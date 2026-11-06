package products

import "math"

// rubyMod1 is Float#% 1 for the non-negative values here: fmod.
func rubyMod1(x float64) float64 { return math.Mod(x, 1) }

// kahanSum is Array#sum over Floats, which compensates with Kahan-Babuska summation.
func kahanSum(xs []float64) float64 {
	f, c := 0.0, 0.0
	for _, x := range xs {
		t := f + x
		if math.Abs(f) >= math.Abs(x) {
			c += (f - t) + x
		} else {
			c += (x - t) + f
		}
		f = t
	}
	return f + c
}
