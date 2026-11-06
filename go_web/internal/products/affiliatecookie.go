package products

import (
	"database/sql"
	"errors"
	"strconv"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// affiliateCookiePrefix is Affiliate::Cookies::AFFILIATE_COOKIE_NAME_PREFIX.
const affiliateCookiePrefix = "_gumroad_affiliate_id_"

// affiliateCookieDays are DirectAffiliate's and GlobalAffiliate's cookie_lifetime. A
// Collaborator has none, so Rails raises setting one.
var affiliateCookieDays = map[string]int{"DirectAffiliate": 30, "GlobalAffiliate": 7}

type affiliateRow struct {
	id, affiliateUserID, sellerID sql.NullInt64
	typ                           string
	deletedAt                     db.NullTime
}

const affiliateColumns = "affiliates.id, affiliates.type, affiliates.affiliate_user_id, affiliates.seller_id, affiliates.deleted_at"

func (a *affiliateRow) dest() []any {
	return []any{&a.id, &a.typ, &a.affiliateUserID, &a.sellerID, &a.deletedAt}
}

// affiliateParamID is AffiliateQueryParams#fetch_affiliate_id, 0 for none.
func affiliateParamID(req *rails.Request) (int64, error) {
	raw := req.Param("affiliate_id")
	if rails.Blank(raw) {
		raw = req.Param("a")
	}
	if list, ok := raw.([]any); ok && len(list) > 0 {
		raw = list[0]
	}
	s, ok := raw.(string)
	if !ok {
		return 0, nil
	}
	id, ok := rails.StringToI(s)
	if !ok {
		// decrypt_numeric of a Bignum.
		return 0, fallback("affiliate id")
	}
	return id, nil
}

// setAffiliateCookie is AffiliateCookie#set_affiliate_cookie.
func (h *handler) setAffiliateCookie(p *page) error {
	id, err := affiliateParamID(p.Req)
	if err != nil || id == 0 {
		return err
	}
	a, err := h.loadAffiliate(p, "affiliates.id = ? LIMIT 1", h.c.IDs.DecryptNumeric(id))
	if err != nil || a == nil {
		return err
	}
	if _, known := affiliateCookieDays[a.typ]; !known && a.typ != "Collaborator" {
		// An unknown subclass raises SubclassNotFound, and a base Affiliate has no seller.
		return fallback("affiliate type")
	}
	if a.typ != "GlobalAffiliate" && a.deletedAt.Valid {
		// affiliate_user.direct_affiliate_accounts.where(seller:).alive.last, which raises
		// without the affiliate's user and matches seller_id IS NULL without the seller's.
		var userFound, sellerFound bool
		if err := h.c.DB.QueryRowContext(p.Ctx, "SELECT EXISTS(SELECT 1 FROM users WHERE users.id = ?), EXISTS(SELECT 1 FROM users WHERE users.id = ?)",
			a.affiliateUserID, a.sellerID).Scan(&userFound, &sellerFound); err != nil {
			return err
		}
		if !userFound || !sellerFound {
			return fallback("affiliate account")
		}
		if a, err = h.loadAffiliate(p, "affiliates.type = 'DirectAffiliate' AND affiliates.affiliate_user_id = ?"+
			" AND affiliates.seller_id = ? AND affiliates.deleted_at IS NULL ORDER BY affiliates.id DESC LIMIT 1",
			a.affiliateUserID.Int64, a.sellerID.Int64); err != nil || a == nil {
			return err
		}
	}
	if a.deletedAt.Valid {
		return nil
	}
	days, ok := affiliateCookieDays[a.typ]
	if !ok {
		return fallback("affiliate type")
	}
	// cookie_id is ObfuscateIds.encrypt(id, padding: false); Time.zone is UTC.
	name := affiliateCookiePrefix + strings.TrimRight(h.c.IDs.Encrypt(a.id.Int64), "=")
	p.Cookies = append(p.Cookies, rails.CookieLine(name, strconv.FormatInt(p.Req.Now.Unix(), 10), rails.CookieDomainAll(p.Req.Host), "",
		p.Req.Now.UTC().AddDate(0, 0, days), true, p.Secure))
	return nil
}

func (h *handler) loadAffiliate(p *page, where string, args ...any) (*affiliateRow, error) {
	a := &affiliateRow{}
	err := h.c.DB.QueryRowContext(p.Ctx, "SELECT "+affiliateColumns+" FROM affiliates WHERE "+where, args...).Scan(a.dest()...)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return a, err
}
