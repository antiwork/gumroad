package products

import (
	"database/sql"

	"github.com/antiwork/gumroad/go_web/internal/db"
)

// signedInUser is the visitor's account.
type signedInUser struct {
	id          int64
	email       sql.NullString
	confirmedAt db.NullTime
}
