package db

import (
	"database/sql"
	"time"
)

// NullTime is sql.NullTime as mysql2 reads a DATETIME: the driver hands over a zero date
// ('0000-00-00') as the zero time, which Rails sees as nil.
type NullTime struct {
	Time  time.Time
	Valid bool
}

// OrNil is the time, or nil when there is none, for the JSON encoder.
func (n NullTime) OrNil() any {
	if !n.Valid {
		return nil
	}
	return n.Time
}

func (n *NullTime) Scan(v any) error {
	var t sql.NullTime
	if err := t.Scan(v); err != nil {
		return err
	}
	n.Time, n.Valid = t.Time, t.Valid && !t.Time.IsZero()
	return nil
}

// Time scans a nullable DATETIME into *p, nil for NULL and for a zero date.
func Time(p **time.Time) sql.Scanner { return timePtr{p} }

type timePtr struct{ p **time.Time }

func (t timePtr) Scan(v any) error {
	var n NullTime
	if err := n.Scan(v); err != nil {
		return err
	}
	*t.p = nil
	if n.Valid {
		*t.p = &n.Time
	}
	return nil
}
