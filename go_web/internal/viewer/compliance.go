package viewer

import (
	"context"
	"database/sql"
	"errors"
	"slices"
	"strings"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/compliance"
	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/pages"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// guardianRequiredBelowAge is UserComplianceInfo::GUARDIAN_REQUIRED_BELOW_AGE.
const guardianRequiredBelowAge = 18

var (
	// nativePayoutCountries is User::Compliance::SUPPORTED_COUNTRIES' alpha2 codes.
	nativePayoutCountries = strings.Fields(`US CA AU GB HK NZ SG CH PL CZ TH BG DK HU KR AE IL TT PH TZ NA AG RO SE MX AR PE NO AL BH JO
		NG AZ IN AO NE SM VN ET BN GY GT TW ID CR BW CL PK TR BA MA RS ZA KE EG CO RW SA JP BD BT LA MZ KZ EC MY UY MU JM LI DO UZ BO MD
		MK PA SV GI OM TN MG PY GH AM LK KW IS QA BS LC SN KH MN GA DZ MO BJ CI GM AT BE HR CY EE FI FR DE GR IE IT LV LT LU MT MC NL PT
		SK SI ES`)
	// paypalPayoutCountries is PaypalPayoutProcessor::PAYOUT_RECEIVING_COUNTRY_CODES.
	paypalPayoutCountries = strings.Fields(`AD AE AR AT AU BE BG BH BM BR BS BW CA CH CL CN CO CR CY CZ DE DK DO EC EE ES FI FO FR GB
		GE GI GL GR GT HK HN HR HU ID IE IL IN IT JM JO JP KE KW KY KZ LI LS LT LU LV MA MC MD MT MU MX MY MZ NI NL NO NZ OM PA PE PH PL
		PT QA RE RO RS SA SE SG SI SK SM SN SV TR TW US UY VE VN ZA`)
	// usOutlyingAreas is Compliance::Countries::US_OUTLYING_AREA_ALPHA2.
	usOutlyingAreas = []string{"AS", "GU", "MP", "PR", "UM", "VI"}
	// guardianStateCountries is StripeBeneficialOwnersManager::COUNTRIES_WITH_STATE_LIST.
	guardianStateCountries = []string{"US", "CA", "AU", "MX", "AE", "IE", "BR", "JP"}
)

// railsTimeZone is ActiveSupport::TimeZone[name]'s tzinfo name and observed offset now. Saves
// keep the column to MAPPING's names, so anything else goes to Rails.
func railsTimeZone(name string, now time.Time) (string, int, error) {
	id, ok := timeZoneMapping[name]
	if !ok {
		return "", 0, pages.Fallback("time zone")
	}
	loc, err := time.LoadLocation(id)
	if err != nil {
		return "", 0, pages.Fallback("time zone")
	}
	_, offset := now.In(loc).Zone()
	return id, offset, nil
}

// canPublishProducts is User#can_publish_products? for a seller who isn't staff.
func (l *Loader) canPublishProducts(ctx context.Context, u *User) (bool, error) {
	rows, err := l.DB.QueryContext(ctx, "SELECT merchant_accounts.charge_processor_id, merchant_accounts.json_data FROM merchant_accounts"+
		" WHERE merchant_accounts.user_id = ? AND merchant_accounts.deleted_at IS NULL AND merchant_accounts.charge_processor_alive_at IS NOT NULL"+
		" AND merchant_accounts.charge_processor_deleted_at IS NULL AND merchant_accounts.charge_processor_id IN ('stripe', 'paypal')", u.ID)
	if err != nil {
		return false, err
	}
	defer rows.Close()
	found := false
	for rows.Next() {
		var processor string
		var data sql.NullString
		if err := rows.Scan(&processor, &data); err != nil {
			return false, err
		}
		if processor == "stripe" && !stripeAccountReadable(data) {
			// Rails classifies the Stripe rows by their json_data, raising on one it can't read.
			return false, pages.Fallback("merchant account json_data")
		}
		found = true
	}
	if err := rows.Err(); err != nil {
		return false, err
	}
	return found || rails.Present(u.PayAddr.String), nil
}

// publishBlockedReason is publish_blocked_reason_for: whether staff rejected the seller's payout
// setup in a note.
func (l *Loader) publishBlockedReason(ctx context.Context, userID int64) (string, error) {
	if l.GumroadAdminID == 0 {
		return "", pages.Fallback("gumroad admin id")
	}
	rows, err := l.DB.QueryContext(ctx, "SELECT comments.json_data FROM comments WHERE comments.commentable_id = ?"+
		" AND comments.commentable_type = 'User' AND comments.comment_type = 'payout_note' AND comments.deleted_at IS NULL"+
		" AND comments.author_id = ? AND (json_data LIKE '%payout_setup_rejection%') ORDER BY comments.created_at DESC, comments.id DESC",
		userID, l.GumroadAdminID)
	if err != nil {
		return "", err
	}
	defer rows.Close()
	for rows.Next() {
		var data sql.NullString
		if err := rows.Scan(&data); err != nil {
			return "", err
		}
		j, ok := jsonDataHash(data)
		if !ok {
			return "", pages.Fallback("comment json_data")
		}
		if j != nil && j.Value("payout_setup_rejection") == true {
			return "payout_setup_rejected", nil
		}
	}
	return "no_payout_method", rows.Err()
}

// activeBankAccountType is active_bank_account's STI type, "" without one; a type Rails can't
// load goes to Rails.
func (l *Loader) activeBankAccountType(ctx context.Context, userID int64) (string, error) {
	var typ sql.NullString
	err := l.DB.QueryRowContext(ctx, "SELECT bank_accounts.type FROM bank_accounts WHERE bank_accounts.user_id = ?"+
		" AND bank_accounts.deleted_at IS NULL ORDER BY bank_accounts.id ASC LIMIT 1", userID).Scan(&typ)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	if !bankAccountTypes[typ.String] {
		return "", pages.Fallback("bank account type")
	}
	return typ.String, nil
}

// noPayoutRail is no_payout_rail_in_compliance_country?.
func noPayoutRail(bank string, info *compliance.Info) (bool, error) {
	if bank != "" {
		return false, nil
	}
	code, err := info.LegalEntityCountryCode()
	if err != nil || code == "" {
		return false, err
	}
	native := slices.Contains(nativePayoutCountries, code) && (code != "AE" || info.IsBusiness)
	paypal := code
	if slices.Contains(usOutlyingAreas, code) {
		paypal = "US"
	}
	return !native && !slices.Contains(paypalPayoutCountries, paypal), nil
}

// underGuardianAge is under_legal_guardian_age?: born after this day 18 years ago, in UTC.
func underGuardianAge(c *compliance.Info, now time.Time) bool {
	if !c.Birthday.Valid {
		return false
	}
	t := rails.AddYears(now.UTC(), -guardianRequiredBelowAge)
	cutoff := time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, time.UTC)
	b := c.Birthday.Time
	return time.Date(b.Year(), b.Month(), b.Day(), 0, 0, 0, 0, time.UTC).After(cutoff)
}

// guardianUnsupported is legal_guardian_unsupported?.
func guardianUnsupported(c *compliance.Info, now time.Time) (bool, error) {
	if !underGuardianAge(c, now) {
		return false, nil
	}
	code, err := compliance.CountryCode(c.Country)
	return code != "" && code != "US", err
}

// guardianRequirementMet is legal_guardian_requirement_met?.
func (l *Loader) guardianRequirementMet(ctx context.Context, c *compliance.Info, now time.Time) (bool, error) {
	if unsupported, err := guardianUnsupported(c, now); err != nil || unsupported {
		return false, err
	}
	if !underGuardianAge(c, now) {
		return true, nil
	}
	if code, err := compliance.CountryCode(c.Country); err != nil || code != "US" {
		return true, err
	}
	if !c.GuardianID.Valid {
		return false, nil
	}
	var g struct {
		deletedAt, dob, acceptedAt                                  db.NullTime
		first, last, email, street, city, state, zip, country, code sql.NullString
		taxID                                                       []byte
		tosIP                                                       sql.NullString
		accepted                                                    sql.NullBool
	}
	err := l.DB.QueryRowContext(ctx, "SELECT guardians.deleted_at, guardians.first_name, guardians.last_name, guardians.email,"+
		" guardians.date_of_birth, guardians.street_address, guardians.city, guardians.state, guardians.zip_code, guardians.country,"+
		" guardians.country_code, guardians.individual_tax_id, guardians.stripe_tos_accepted, guardians.stripe_tos_accepted_at,"+
		" guardians.stripe_tos_ip FROM guardians WHERE guardians.id = ? LIMIT 1", c.GuardianID.Int64).
		Scan(&g.deletedAt, &g.first, &g.last, &g.email, &g.dob, &g.street, &g.city, &g.state, &g.zip, &g.country, &g.code, &g.taxID,
			&g.accepted, &g.acceptedAt, &g.tosIP)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	present := func(fields ...sql.NullString) bool {
		for _, f := range fields {
			if rails.Blank(f.String) {
				return false
			}
		}
		return true
	}
	if g.deletedAt.Valid || !present(g.first, g.last, g.email) || !g.dob.Valid || !present(g.street, g.city) {
		return false, nil
	}
	// state_required? reads the country only once the fields before it are in.
	stateCode := g.code.String
	if rails.Blank(stateCode) {
		if stateCode, err = compliance.CountryCode(g.country); err != nil {
			return false, err
		}
	}
	if slices.Contains(guardianStateCountries, stateCode) && rails.Blank(g.state.String) {
		return false, nil
	}
	return present(g.zip, g.country) && len(g.taxID) > 0 && g.accepted.Bool && g.acceptedAt.Valid && rails.Present(g.tosIP.String), nil
}

// jsonDataHash is a json_data column as the JSON coder loads it, nil when blank; false where
// Rails raises: text the coder can't load, or a value that isn't a Hash.
func jsonDataHash(s sql.NullString) (*rails.Hash, bool) {
	if !s.Valid || s.String == "" {
		return nil, true
	}
	v, err := rails.ParseJSON([]byte(s.String))
	if err != nil {
		return nil, false
	}
	switch v := v.(type) {
	case nil:
		return nil, true
	case *rails.Hash:
		return v, true
	}
	return nil, false
}

// stripeAccountReadable is whether Rails can classify a Stripe merchant account by its
// json_data's meta.stripe_connect.
func stripeAccountReadable(raw sql.NullString) bool {
	j, ok := jsonDataHash(raw)
	if !ok {
		return false
	}
	if j == nil {
		return true
	}
	switch j.Value("meta").(type) {
	case nil, *rails.Hash:
		return true
	}
	return false
}
