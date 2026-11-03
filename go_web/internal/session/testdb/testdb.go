// Package testdb opens the MySQL test database named by GO_WEB_TEST_MYSQL_DSN, with the
// connection settings internal/db uses, and tracks the rows a test inserts.
package testdb

import (
	"database/sql"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/go-sql-driver/mysql"
)

// Fixture ids stay in this range, which other packages' tests leave alone.
const (
	MinID = 1_000_000
	MaxID = 1_999_999
)

// Open skips the test when GO_WEB_TEST_MYSQL_DSN is unset.
func Open(t testing.TB) *sql.DB {
	t.Helper()
	dsn := os.Getenv("GO_WEB_TEST_MYSQL_DSN")
	if dsn == "" {
		// CI loads the schema and sets the DSN, so a skip there would hide these tests.
		if os.Getenv("CI") != "" {
			t.Fatal("GO_WEB_TEST_MYSQL_DSN is not set")
		}
		t.Skip("GO_WEB_TEST_MYSQL_DSN is not set")
	}
	cfg, err := mysql.ParseDSN(dsn)
	if err != nil {
		t.Fatal(err)
	}
	cfg.ParseTime = true
	cfg.Loc = time.UTC
	cfg.Collation = "utf8mb4_unicode_ci"
	if cfg.Params == nil {
		cfg.Params = map[string]string{}
	}
	cfg.Params["sql_mode"] = "'NO_ENGINE_SUBSTITUTION'"
	conn, err := sql.Open("mysql", cfg.FormatDSN())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	if err := conn.Ping(); err != nil {
		t.Fatal(err)
	}
	return conn
}

// Insert adds a row and deletes it when the test ends. The row's id must be in range.
func Insert(t testing.TB, conn *sql.DB, table string, row map[string]any) {
	t.Helper()
	id, ok := row["id"].(int64)
	if !ok || id < MinID || id > MaxID {
		t.Fatalf("%s fixture id %v is outside %d..%d", table, row["id"], MinID, MaxID)
	}
	columns := make([]string, 0, len(row))
	values := make([]any, 0, len(row))
	for column, value := range row {
		columns = append(columns, "`"+column+"`")
		values = append(values, value)
	}
	placeholders := strings.TrimSuffix(strings.Repeat("?,", len(columns)), ",")
	query := fmt.Sprintf("INSERT INTO `%s` (%s) VALUES (%s)", table, strings.Join(columns, ","), placeholders)
	if _, err := conn.Exec(query, values...); err != nil {
		t.Fatalf("insert %s: %v", table, err)
	}
	t.Cleanup(func() { conn.Exec("DELETE FROM `"+table+"` WHERE id = ?", id) })
}

// CleanupWhere deletes rows the code under test inserts, when the test ends.
func CleanupWhere(t testing.TB, conn *sql.DB, table, where string, args ...any) {
	t.Helper()
	t.Cleanup(func() {
		if _, err := conn.Exec("DELETE FROM `"+table+"` WHERE "+where, args...); err != nil {
			t.Errorf("cleanup %s: %v", table, err)
		}
	})
}

// User inserts a users row with the NOT NULL columns filled in.
func User(t testing.TB, conn *sql.DB, id int64, extra map[string]any) {
	t.Helper()
	row := map[string]any{"id": id, "recommendation_type": "own_products", "encrypted_password": "$2a$11$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQ"}
	for k, v := range extra {
		row[k] = v
	}
	Insert(t, conn, "users", row)
}
