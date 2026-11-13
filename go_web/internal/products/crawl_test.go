package products

import (
	"database/sql"
	"testing"
)

func TestRecurrenceLabel(t *testing.T) {
	months := func(n int64) sql.NullInt64 { return sql.NullInt64{Int64: n, Valid: true} }
	for _, c := range []struct {
		recurrence string
		duration   sql.NullInt64
		want       string
		ok         bool
	}{
		{"", months(12), "", true},
		{"monthly", sql.NullInt64{}, "a month", true},
		{"unknown", sql.NullInt64{}, "", true},
		{"yearly", months(12), "once", true},
		{"monthly", months(6), "a month x 6", true},
		{"quarterly", months(7), "every 3 months x 2", true},
		{"monthly", months(0), "a month x 0", true},
		{"yearly", months(-1), "a year x -1", true},
		{"unknown", months(6), "", false},
	} {
		got, ok := recurrenceLabel(c.recurrence, c.duration)
		if got != c.want || ok != c.ok {
			t.Errorf("recurrenceLabel(%q, %v) = %q, %v; want %q, %v", c.recurrence, c.duration, got, ok, c.want, c.ok)
		}
	}
}
