// Package beacons ports the analytics and progress beacons: MediaLocationsController#create
// and its mobile twin, LinksController#increment_views and #track_user_action,
// EventsController#create, and the JSON variant of LinksController#cart_items_count.
package beacons

import (
	"database/sql"
	"errors"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/antiwork/gumroad/go_web/internal/geoip"
	"github.com/antiwork/gumroad/go_web/internal/oauth"
	"github.com/antiwork/gumroad/go_web/internal/obfuscate"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session"
	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

type Deps struct {
	Env *web.Environment
	// Stack is the shared Rack emulation, built with CUSTOM_DOMAIN.
	Stack *rails.Stack
	// DB is the MySQL primary.
	DB *sql.DB
	// Redis is $redis (REDIS_HOST), for Impersonate's keys.
	Redis   redis.Cmdable
	Sidekiq *sidekiq.Client
	// GeoIP may be nil, as GEOIP is when lib/GeoIP2-City.mmdb is missing.
	GeoIP *geoip.Reader
	IDs   *obfuscate.IDs
	// SecretKeyBase is SECRET_KEY_BASE.
	SecretKeyBase string
	// MobileToken is MOBILE_TOKEN, which Api::Mobile::BaseController compares.
	MobileToken string
	// CustomDomain and BranchDeployment are CUSTOM_DOMAIN and BRANCH_DEPLOYMENT, which name
	// the session cookie.
	CustomDomain     string
	BranchDeployment bool
	Now              func() time.Time
}

type handlers struct {
	deps          Deps
	stack         *rails.Stack
	codec         *session.Codec
	resolver      *session.Resolver
	oauth         *oauth.Store
	hosts         *hosts
	views         *rails.MessageVerifier
	sessionCookie string
}

func Register(app *web.App, deps Deps) error {
	switch {
	case deps.Env == nil || deps.Stack == nil || deps.DB == nil || deps.Redis == nil || deps.Sidekiq == nil || deps.IDs == nil:
		return errors.New("beacons: Env, Stack, DB, Redis, Sidekiq and IDs are required")
	case deps.MobileToken == "":
		// secure_compare against a nil MOBILE_TOKEN raises in Rails on every mobile call.
		return errors.New("MOBILE_TOKEN is not set")
	}
	if deps.Now == nil {
		deps.Now = time.Now
	}
	codec, err := session.NewCodec(deps.SecretKeyBase)
	if err != nil {
		return err
	}
	views, err := rails.NewMessageVerifier(deps.SecretKeyBase, "product_analytics_view")
	if err != nil {
		return err
	}
	users := &session.Users{DB: deps.DB}
	h := &handlers{
		deps:          deps,
		stack:         deps.Stack,
		codec:         codec,
		resolver:      &session.Resolver{Users: users, Redis: deps.Redis, Codec: codec},
		oauth:         &oauth.Store{DB: deps.DB, Users: users},
		hosts:         newHosts(deps.Env, deps.DB),
		views:         views,
		sessionCookie: session.CookieName(deps.Env.Name, deps.CustomDomain, deps.BranchDeployment),
	}

	tracking := scopeGumroad | scopeProductCustomDomain | scopeUserCustomDomain
	storefront := scopeGumroad | scopeUserCustomDomain

	mediaLocations := h.handle(action{controller: "media_locations", name: "create", scopes: storefront, run: h.mediaLocation})
	for _, path := range []string{"/media_locations", "/media_locations.json"} {
		app.Handle("POST "+path, "MediaLocationsController#create", mediaLocations)
	}
	mobile := h.handle(action{controller: "api/mobile/media_locations", name: "create", scopes: scopeAPI, checkSuspended: true, run: h.mobileMediaLocation})
	for _, path := range []string{"/mobile/media_locations", "/mobile/media_locations.json"} {
		app.Handle("POST "+path, "Api::Mobile::MediaLocationsController#create", mobile)
	}

	incrementViews := h.handle(action{controller: "links", name: "increment_views", scopes: tracking, checkSuspended: true, run: h.incrementViews})
	for _, suffix := range []string{"", ".json", ".gif"} {
		for _, method := range []string{"GET", "POST"} {
			app.Handle(method+" /links/{id}/increment_views"+suffix, "LinksController#increment_views", incrementViews)
		}
	}
	userAction := h.handle(action{controller: "links", name: "track_user_action", scopes: tracking, checkSuspended: true, run: h.trackUserAction})
	for _, suffix := range []string{"", ".json"} {
		app.Handle("POST /links/{id}/track_user_action"+suffix, "LinksController#track_user_action", userAction)
	}
	events := h.handle(action{controller: "events", name: "create", scopes: storefront, checkSuspended: true, run: h.createEvent})
	for _, suffix := range []string{"", ".json"} {
		app.Handle("POST /events/track_user_action"+suffix, "EventsController#create", events)
	}

	cart := h.handle(action{controller: "links", name: "cart_items_count", scopes: storefront, run: h.cartItemsCount})
	for _, suffix := range []string{"", ".json"} {
		app.Handle("GET /cart_items_count"+suffix, "LinksController#cart_items_count", cart)
	}
	return nil
}
