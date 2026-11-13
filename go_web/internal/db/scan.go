package db

import (
	"context"
	"database/sql"
)

// ScanNamed runs a SELECT * and scans each row's columns that bind names into its pointers,
// skipping the rest, then calls what bind returned.
func ScanNamed(ctx context.Context, conn *sql.DB, bind func(cols map[string]any) func(), query string, args ...any) error {
	rows, err := conn.QueryContext(ctx, query, args...)
	if err != nil {
		return err
	}
	defer rows.Close()
	names, err := rows.Columns()
	if err != nil {
		return err
	}
	for rows.Next() {
		cols := map[string]any{}
		after := bind(cols)
		dest := make([]any, len(names))
		for i, n := range names {
			if d, ok := cols[n]; ok {
				dest[i] = d
			} else {
				dest[i] = new(sql.RawBytes)
			}
		}
		if err := rows.Scan(dest...); err != nil {
			return err
		}
		after()
	}
	return rows.Err()
}
