package db

import (
	"testing"
	"time"
)

func TestZeroDatesReadAsNil(t *testing.T) {
	at := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	for _, c := range []struct {
		in    any
		valid bool
	}{{nil, false}, {time.Time{}, false}, {at, true}} {
		var n NullTime
		if err := n.Scan(c.in); err != nil || n.Valid != c.valid {
			t.Errorf("NullTime.Scan(%v) = %v, %v", c.in, n.Valid, err)
		}
		p := &at
		if err := Time(&p).Scan(c.in); err != nil || (p != nil) != c.valid {
			t.Errorf("Time.Scan(%v) = %v, %v", c.in, p, err)
		}
	}
}
