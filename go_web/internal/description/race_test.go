//go:build race

package description

// The race detector slows this package's tight loops about tenfold.
func init() { slowdown = 10 }
