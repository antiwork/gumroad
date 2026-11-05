package pages

import (
	"context"
	"errors"

	"github.com/antiwork/gumroad/go_web/internal/flipper"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

// Shared is what InertiaRendering's share blocks read from config. The hashes it hands out
// are shared by every request and must not be changed.
type Shared struct {
	// disableStripeSignup is Feature.active?(:disable_stripe_signup).
	disableStripeSignup func(context.Context) (bool, error)
	designSettings      *rails.RHash
	designSettingsJSON  string
	domainSettings      *rails.RHash
}

func NewShared(env *web.Environment, disableStripeSignup func(context.Context) (bool, error)) *Shared {
	design := rails.NewRHash().Sym("font", rails.NewRHash().
		Sym("name", "ABC Favorit").
		Sym("url", env.AssetHost()+"/fonts/ABCFavorit-Regular.woff2"))
	return &Shared{
		disableStripeSignup: disableStripeSignup,
		designSettings:      design,
		designSettingsJSON:  rails.EncodeJSON(design),
		domainSettings: rails.NewRHash().
			Sym("scheme", env.Protocol).
			Sym("app_domain", env.Domain).
			Sym("root_domain", env.RootDomain).
			Sym("short_domain", env.ShortDomain).
			Sym("discover_domain", env.DiscoverDomain).
			Sym("third_party_analytics_domain", env.ThirdPartyAnalyticsDomain).
			Sym("api_domain", env.APIDomain),
	}
}

// Request is what the share blocks read from one request. Headers come from Req, which
// joins a repeated one as Puma does.
type Request struct {
	Req     *rails.Request
	Session *session.Session
	// CSRFToken is form_authenticity_token, and ScriptNonce SecureHeaders' script nonce.
	CSRFToken, ScriptNonce string
	// Title is page_title.
	Title string
}

func (r Request) isMobile() bool { return r.Session.IsMobile(r.Req.Header("User-Agent")) }

// ErrUnported is a request whose shared props only Rails can build.
var ErrUnported = errors.New("shared props this port leaves to Rails")

// DesignSettingsJSON is RenderingExtension.design_settings as the layout writes it.
func (s *Shared) DesignSettingsJSON() string { return s.designSettingsJSON }

// UserAgentInfoJSON is RenderingExtension.user_agent_info as the layout writes it.
func UserAgentInfoJSON(r Request) string {
	if r.isMobile() {
		return `{"is_mobile":true}`
	}
	return `{"is_mobile":false}`
}

// SignedOut is the props every share block adds for a request without logged_in_user, in
// inertia_rails' order: errors, then the blocks as declared. It assumes a controller with no
// share blocks of its own and an action outside buyer_currency_footer_actions; the caller
// deletes the flash it read when it commits the session, as commit_flash does.
func (s *Shared) SignedOut(ctx context.Context, r Request) (*rails.RHash, error) {
	if r.Session.Get("inertia_errors") != nil {
		// The errors prop would be the session's, not {}.
		return nil, ErrUnported
	}
	locale, ok := Locale(r.Req.Header("Accept-Language"))
	if !ok {
		return nil, ErrUnported
	}
	// Before the flag, so a request Rails takes doesn't wait on Redis.
	flash, err := FlashProps(r.Session)
	if err != nil {
		return nil, err
	}
	disableStripeSignup, err := s.disableStripeSignup(ctx)
	if errors.Is(err, flipper.ErrUnevaluable) {
		return nil, ErrUnported
	}
	if err != nil {
		return nil, err
	}
	return rails.NewRHash().
		Sym("errors", rails.NewRHash()).
		Sym("design_settings", s.designSettings).
		Sym("domain_settings", s.domainSettings).
		Sym("user_agent_info", rails.NewRHash().Sym("is_mobile", r.isMobile())).
		Sym("logged_in_user", nil).
		Sym("current_seller", nil).
		Sym("csp_nonce", r.ScriptNonce).
		Sym("locale", locale).
		Sym("feature_flags", rails.NewRHash().Sym("disable_stripe_signup", disableStripeSignup)).
		Sym("authenticity_token", r.CSRFToken).
		Sym("flash", flash).
		Sym("title", r.Title), nil
}

// flashStatuses is InertiaRendering::FLASH_STATUSES, loudest first.
var flashStatuses = [][2]string{{"alert", "danger"}, {"warning", "warning"}, {"info", "info"}, {"notice", "success"}}

// FlashProps is inertia_flash_props over the flash the session brought in, which
// FlashHash.from_session_value loads without its discarded keys. A shape it would raise on,
// or one other than a list of string keys to discard, goes to Rails.
func FlashProps(s *session.Session) (any, error) {
	stored := s.Get("flash")
	if stored == nil {
		return nil, nil
	}
	value, ok := stored.(*rails.Hash)
	if !ok {
		// from_session_value's else branch: an empty FlashHash.
		return nil, nil
	}
	flashes, ok := value.Value("flashes").(*rails.Hash)
	if !ok {
		return nil, ErrUnported
	}
	discarded := map[string]bool{}
	if discard := value.Value("discard"); discard != nil {
		list, ok := discard.([]any)
		if !ok {
			return nil, ErrUnported
		}
		for _, k := range list {
			key, ok := k.(string)
			if !ok {
				return nil, ErrUnported
			}
			discarded[key] = true
		}
	}
	for _, status := range flashStatuses {
		if discarded[status[0]] {
			continue
		}
		if message := flashes.Value(status[0]); rails.Present(message) {
			return rails.NewRHash().Sym("message", message).Sym("status", status[1]), nil
		}
	}
	return nil, nil
}
