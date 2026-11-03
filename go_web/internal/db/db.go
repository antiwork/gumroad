// Package db opens the MySQL primary the way config/database.yml configures web Puma.
package db

import (
	"database/sql"
	"fmt"
	"time"

	"github.com/go-sql-driver/mysql"
)

const (
	// Idle equals open, so a burst reuses connections instead of redialing.
	maxConns        = 32
	connMaxLifetime = 5 * time.Minute
	// database.yml's max_execution_time; the request deadline normally ends a query first.
	maxExecutionTime = "300000"
)

// Open reads the DATABASE_* variables Rails reads. Web Puma uses the primary only, and so
// does this service: replica lag would let a beacon read a row it can't see yet.
func Open(getenv func(string) string) (*sql.DB, error) {
	cfg := mysql.NewConfig()
	cfg.Net = "tcp"
	cfg.Addr = getenv("DATABASE_HOST") + ":" + getenv("DATABASE_PORT")
	cfg.DBName = getenv("DATABASE_NAME")
	cfg.User = getenv("DATABASE_USERNAME")
	cfg.Passwd = getenv("DATABASE_PASSWORD")
	cfg.Collation = "utf8mb4_unicode_ci"
	cfg.ParseTime = true
	// Rails reads and writes datetimes as UTC.
	cfg.Loc = time.UTC
	cfg.Timeout = 5 * time.Second
	// Client-side interpolation, as mysql2 does: otherwise every query is a PREPARE/EXECUTE/CLOSE.
	cfg.InterpolateParams = true
	cfg.Params = map[string]string{
		"sql_mode":           "'NO_ENGINE_SUBSTITUTION'",
		"max_execution_time": maxExecutionTime,
	}
	if cfg.DBName == "" || getenv("DATABASE_HOST") == "" {
		return nil, fmt.Errorf("DATABASE_HOST and DATABASE_NAME must be set")
	}
	conn, err := sql.Open("mysql", cfg.FormatDSN())
	if err != nil {
		return nil, err
	}
	conn.SetMaxOpenConns(maxConns)
	conn.SetMaxIdleConns(maxConns)
	conn.SetConnMaxLifetime(connMaxLifetime)
	return conn, nil
}
