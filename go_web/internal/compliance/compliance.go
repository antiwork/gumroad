// Package compliance is a user's UserComplianceInfo as Rails' compliance helpers read it.
package compliance

import (
	"context"
	"database/sql"
	"errors"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/pages"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// Info is a user's alive user_compliance_info row.
type Info struct {
	Country, BusinessCountry sql.NullString
	IsBusiness               bool
	Birthday                 db.NullTime
	GuardianID               sql.NullInt64
}

// Load is the user's alive_user_compliance_info, nil without one.
func Load(ctx context.Context, conn *sql.DB, userID int64) (*Info, error) {
	c := &Info{}
	var business sql.NullBool
	err := conn.QueryRowContext(ctx, "SELECT user_compliance_info.country, user_compliance_info.business_country, user_compliance_info.is_business,"+
		" user_compliance_info.birthday, user_compliance_info.guardian_id FROM user_compliance_info WHERE user_compliance_info.user_id = ?"+
		" AND user_compliance_info.deleted_at IS NULL ORDER BY user_compliance_info.id DESC LIMIT 1", userID).
		Scan(&c.Country, &c.BusinessCountry, &business, &c.Birthday, &c.GuardianID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	c.IsBusiness = business.Bool
	return c, err
}

// CountryCode is Compliance::Countries.find_by_name(name)&.alpha2, "" for nil; a name this
// port has no answer for goes to Rails.
func CountryCode(name sql.NullString) (string, error) {
	if rails.Blank(name.String) {
		return "", nil
	}
	code, ok := countryCodes[name.String]
	if !ok {
		return "", pages.Fallback("compliance country")
	}
	return code, nil
}

// LegalEntityCountryCode is the business country's code for a business that has one, else the
// individual's; "" without compliance info.
func (c *Info) LegalEntityCountryCode() (string, error) {
	if c == nil {
		return "", nil
	}
	if c.IsBusiness {
		code, err := CountryCode(c.BusinessCountry)
		if err != nil || code != "" {
			return code, err
		}
	}
	return CountryCode(c.Country)
}
