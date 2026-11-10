// Package errorreport sends go_web's errors to the Sentry project Rails reports to. An ERROR
// line stands for what Rails would raise to its 500 page or pass to ErrorNotifier, so it is
// reported, unless it is marked LogOnly.
package errorreport

import (
	"context"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/getsentry/sentry-go"
)

const module = "github.com/antiwork/gumroad/go_web"

// LogOnly marks an ERROR line that copies a Rails.logger.error line, which Rails doesn't
// report. Like Request, it prints nothing.
var LogOnly = slog.Any("log_only", logOnly{})

type logOnly struct{}

func (logOnly) LogValue() slog.Value { return slog.GroupValue() }

// Request is the attribute App adds to a request's logger, so its events carry the request
// and its X-Request-Id.
func Request(r *http.Request, id string) slog.Attr { return slog.Any("request", request{r, id}) }

type request struct {
	r  *http.Request
	id string
}

func (request) LogValue() slog.Value { return slog.GroupValue() }

// railsFilterParameters is config.filter_parameters (filter_parameter_logging.rb). sentry-go
// matches them as Rails does, as part of a name in any case, on top of its own key/token/secret.
var railsFilterParameters = []string{
	"password", "cc_number", "number", "expiry_date", "cc_expiry", "cvc", "account_number", "account_number_repeated", "passphrase",
	"chargeable", "tax_id", "individual_tax_id", "business_tax_id", "ssn_first_three", "ssn_middle_two", "ssn_last_four",
	"access_token", "bearer_token", "mobile_token", "device_code", "user_code", "migration_code", "account_setup_token", "client_secret", "license_key",
}

// options keeps what sentry-go's default (SendDefaultPII off) leaves out, which setting
// DataCollection otherwise drops: cookies, bodies, user info and the buyer's address headers.
func options(dsn, environment, release string) sentry.ClientOptions {
	return sentry.ClientOptions{
		Dsn: dsn, Environment: environment, Release: release,
		DataCollection: &sentry.DataCollection{
			UserInfo:   sentry.Set(false),
			Cookies:    &sentry.KeyValueCollectionBehavior{Mode: sentry.CollectionOff},
			HTTPBodies: []sentry.BodyType{},
			HTTPHeaders: &sentry.HeaderCollectionConfig{Request: &sentry.KeyValueCollectionBehavior{
				Mode: sentry.CollectionDenyList, Terms: []string{"forwarded", "-ip", "remote-", "via", "-user"},
			}},
			QueryParams: &sentry.KeyValueCollectionBehavior{Mode: sentry.CollectionDenyList, Terms: railsFilterParameters},
		},
	}
}

// Init reports to dsn where Rails does, in production and staging (enabled_environments),
// and says whether it does.
func Init(dsn, environment, release string) (bool, error) {
	if dsn == "" || (environment != "production" && environment != "staging") {
		return false, nil
	}
	if err := sentry.Init(options(dsn, environment, release)); err != nil {
		return false, err
	}
	sentry.ConfigureScope(func(s *sentry.Scope) { s.SetTag("service", "go_web") })
	return true, nil
}

// Flush waits up to timeout for events still queued.
func Flush(timeout time.Duration) { sentry.Flush(timeout) }

// Handler passes every record to next, and reports the ERROR ones.
type Handler struct {
	next  slog.Handler
	hub   *sentry.Hub
	attrs []slog.Attr
}

// NewHandler reports to the hub Init sets up; until then, or without it, nothing is sent.
func NewHandler(next slog.Handler) *Handler { return &Handler{next: next, hub: sentry.CurrentHub()} }

func (h *Handler) Enabled(ctx context.Context, level slog.Level) bool {
	return h.next.Enabled(ctx, level)
}

func (h *Handler) Handle(ctx context.Context, rec slog.Record) error {
	if rec.Level >= slog.LevelError && h.hub.Client().IsEnabled() {
		h.capture(rec)
	}
	return h.next.Handle(ctx, rec)
}

func (h *Handler) WithAttrs(attrs []slog.Attr) slog.Handler {
	next := *h
	next.next = h.next.WithAttrs(attrs)
	next.attrs = append(h.attrs[:len(h.attrs):len(h.attrs)], attrs...)
	return &next
}

// WithGroup doesn't prefix the attributes Sentry gets; go_web logs no groups.
func (h *Handler) WithGroup(name string) slog.Handler {
	next := *h
	next.next = h.next.WithGroup(name)
	return &next
}

func (h *Handler) capture(rec slog.Record) {
	attrs := h.attrs[:len(h.attrs):len(h.attrs)]
	rec.Attrs(func(a slog.Attr) bool { attrs = append(attrs, a); return true })
	event := sentry.NewEvent()
	logged := sentry.Context{}
	for _, a := range attrs {
		if a.Value.Kind() != slog.KindLogValuer {
			logged[a.Key] = a.Value.String()
			continue
		}
		switch v := a.Value.Any().(type) {
		case logOnly:
			return
		case request:
			event.Request = sentry.NewRequest(v.r)
			event.Tags["request_id"] = v.id
		default:
			logged[a.Key] = a.Value.Resolve().String()
		}
	}
	event.Contexts["log"] = logged
	event.Level = sentry.LevelError
	event.Message = rec.Message
	// One issue per message, as Rails' ErrorNotifier.notify(message) groups; the error text
	// varies by host and connection.
	event.Fingerprint = []string{rec.Message}
	event.Logger = "go_web"
	event.Threads = []sentry.Thread{{Stacktrace: callSite(), Current: true}}
	h.hub.CaptureEvent(event)
}

// callSite is the stack up to the logging call, without slog's and this package's frames.
// The image is built with -trimpath, so sentry-go can't tell go_web's frames apart itself.
func callSite() *sentry.Stacktrace {
	st := sentry.NewStacktrace()
	frames := st.Frames
	for len(frames) > 0 {
		m := frames[len(frames)-1].Module
		if m != "log/slog" && m != module+"/internal/errorreport" {
			break
		}
		frames = frames[:len(frames)-1]
	}
	for i := range frames {
		frames[i].InApp = strings.HasPrefix(frames[i].Module, module)
	}
	st.Frames = frames
	return st
}
