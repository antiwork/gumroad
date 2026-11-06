package beacons

import (
	"context"
	"database/sql"
	"errors"
	"regexp"
	"slices"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/customdomain"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

// scope is a config/routes.rb constraints block a request can land in.
type scope int

const (
	scopeGumroad scope = 1 << iota
	scopeAPI
	scopeUserCustomDomain
	scopeProductCustomDomain
)

// hosts answers the routing constraints: GumroadDomainConstraint, ApiDomainConstraint,
// ProductCustomDomainConstraint and UserCustomDomainConstraint.
type hosts struct {
	env *web.Environment
	db  *sql.DB
	// Subdomain.subdomain_request?'s pattern, which interpolates ROOT_DOMAIN unescaped.
	subdomain *regexp.Regexp
	// THIRD_PARTY_ANALYTICS_DOMAIN's constraint, also an unescaped interpolation.
	thirdPartyAnalytics *regexp.Regexp
}

// Development's domain carries a port, which request.host never has, so it never matches.
var thirdPartyAnalyticsDomains = map[string]string{
	"production":  "gumroad-analytics.com",
	"staging":     "staging.gumroad-analytics.com",
	"development": `analytics.localhost:\d+`,
}

func newHosts(env *web.Environment, db *sql.DB) *hosts {
	return &hosts{
		env:                 env,
		db:                  db,
		subdomain:           web.SubdomainRequestPattern(env.RootDomain),
		thirdPartyAnalytics: regexp.MustCompile(thirdPartyAnalyticsDomains[env.Name]),
	}
}

// scopes returns every constraints block of allowed that matches host, checking the
// cheap ones first.
func (h *hosts) scopes(ctx context.Context, host string, allowed scope) (scope, error) {
	var matched scope
	if allowed&scopeGumroad != 0 && h.env.IsGumroadHost(host) {
		matched |= scopeGumroad
	}
	if allowed&scopeAPI != 0 && (h.env.Name == "development" || slices.Contains(h.env.ValidAPIRequestHosts, host)) {
		matched |= scopeAPI
	}
	if matched != 0 || allowed&(scopeUserCustomDomain|scopeProductCustomDomain) == 0 {
		return matched, nil
	}
	// A seller subdomain is the common case, and a match there needs no custom domain read:
	// the action is the same whichever block routes it.
	if allowed&scopeUserCustomDomain != 0 && h.subdomain.MatchString(host) {
		if seller, err := h.subdomainSellerExists(ctx, host); err != nil || seller {
			return scopeUserCustomDomain, err
		}
	}
	domain, err := h.customDomain(ctx, host)
	if err != nil {
		return 0, err
	}
	if allowed&scopeProductCustomDomain != 0 && domain != nil && domain.productExists {
		matched |= scopeProductCustomDomain
	}
	if allowed&scopeUserCustomDomain != 0 && domain != nil && strings.TrimSpace(domain.ownerUsername) != "" {
		matched |= scopeUserCustomDomain
	}
	return matched, nil
}

// isThirdPartyAnalytics is the constraints(host: /THIRD_PARTY_ANALYTICS_DOMAIN/) block
// at the top of routes.rb, which catches every GET on those hosts first.
func (h *hosts) isThirdPartyAnalytics(host string) bool {
	return h.thirdPartyAnalytics.MatchString(host)
}

// subdomainSellerExists is Subdomain.find_seller_by_request(request).present? for a host
// subdomain_request? accepts.
func (h *hosts) subdomainSellerExists(ctx context.Context, host string) (bool, error) {
	label, _, _ := strings.Cut(host, ".")
	query, arg := `SELECT 1 FROM users WHERE username = ? AND deleted_at IS NULL LIMIT 1`, strings.ReplaceAll(label, "-", "_")
	if isDigits(label) {
		query, arg = `SELECT 1 FROM users WHERE external_id = ? AND deleted_at IS NULL LIMIT 1`, label
	}
	var one int
	err := h.db.QueryRowContext(ctx, query, arg).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

type customDomain struct {
	productExists bool
	ownerUsername string
}

// customDomain is CustomDomain.find_by_host, with the product and owner it points at.
func (h *hosts) customDomain(ctx context.Context, host string) (*customDomain, error) {
	names := customdomain.Names(host)
	if names == nil {
		return nil, nil
	}
	query, args := `custom_domains.domain = ?`, []any{names[0]}
	if len(names) == 2 {
		// find_by(domain:) || find_by(domain: "www.#{domain}"): the apex wins.
		query, args = `custom_domains.domain IN (?, ?)`, []any{names[0], names[1]}
	}
	d := &customDomain{}
	err := h.db.QueryRowContext(ctx, `SELECT links.id IS NOT NULL, COALESCE(users.username, '')
		FROM custom_domains
		LEFT JOIN links ON links.id = custom_domains.product_id
		LEFT JOIN users ON users.id = custom_domains.user_id
		WHERE `+query+` AND custom_domains.deleted_at IS NULL
		ORDER BY custom_domains.domain = ? DESC LIMIT 1`, append(args, args[0])...).Scan(&d.productExists, &d.ownerUsername)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return d, nil
}

func isDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}
