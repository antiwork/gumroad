package web

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"path"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/antiwork/gumroad/go_web/internal/errorreport"
)

// App routes the ported Rails actions. It sets the response headers every Rails response
// carries, except CSP and rack-cors' Vary, which these routes don't need.
type App struct {
	env       *Environment
	logger    *slog.Logger
	redirects *SubdomainRedirects
	mux       *http.ServeMux
	unclean   []uncleanRoute
}

// uncleanRoute serves, under prefix, a path ServeMux would redirect to its cleaned form.
type uncleanRoute struct {
	prefix string
	h      http.Handler
}

// NewApp takes $redis (REDIS_HOST), which holds the subdomain redirect table.
func NewApp(env *Environment, logger *slog.Logger, redisClient redis.Cmdable) *App {
	a := &App{env: env, logger: logger, redirects: NewSubdomainRedirects(redisClient, env, logger), mux: http.NewServeMux()}
	// The target group's health check, so it skips everything a Rails action runs.
	a.mux.HandleFunc("GET /healthcheck", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", TextPlain)
		io.WriteString(w, "healthcheck")
	})
	return a
}

type loggerKey struct{}

// Logger returns the request's logger, tagged with its request ID.
func Logger(r *http.Request) *slog.Logger {
	if logger, ok := r.Context().Value(loggerKey{}).(*slog.Logger); ok {
		return logger
	}
	return slog.Default()
}

// Handle registers the replacement for a Rails action, named "Controller#action" so log
// searches by controller keep working. It runs what ApplicationController and the Rack stack
// do around the action: the custom subdomain redirect, panic recovery and one access log line.
func (a *App) Handle(pattern, action string, h http.Handler) { a.handle(pattern, action, h, true) }

// HandlePage is Handle for a page action, which runs the custom subdomain redirect itself
// (see Redirects), after the before_actions Rails runs first.
func (a *App) HandlePage(pattern, action string, h http.Handler) { a.handle(pattern, action, h, false) }

// Redirects is the custom subdomain redirect table HandlePage leaves to the action.
func (a *App) Redirects() *SubdomainRedirects { return a.redirects }

// HandleUncleanPage serves a path under prefix that ServeMux would redirect to its cleaned
// form instead: Rails' router squeezes repeated slashes itself and routes such a path as is.
func (a *App) HandleUncleanPage(prefix, action string, h http.Handler) {
	a.unclean = append(a.unclean, uncleanRoute{prefix, a.wrap(action, h, false)})
}

func (a *App) handle(pattern, action string, h http.Handler, redirect bool) {
	a.mux.Handle(pattern, a.wrap(action, h, redirect))
}

func (a *App) wrap(action string, h http.Handler, redirect bool) http.Handler {
	controller, actionName, found := strings.Cut(action, "#")
	if !found {
		panic("action must be Controller#action, got " + action)
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		id := requestID(r)
		logger := a.logger.With("uuid", id, errorreport.Request(r, id))
		r = r.WithContext(context.WithValue(r.Context(), loggerKey{}, logger))
		rec := &statusRecorder{ResponseWriter: w}
		a.setDefaultHeaders(rec.Header(), id)

		defer func() {
			if err := recover(); err != nil {
				if err == http.ErrAbortHandler {
					panic(err)
				}
				logger.Error("panic serving request", "path", r.URL.Path, "error", err)
				if rec.status == 0 {
					InternalServerError(rec)
				}
			}
			status := rec.status
			if status == 0 {
				status = http.StatusOK
			}
			logger.LogAttrs(r.Context(), slog.LevelInfo, "request",
				slog.String("method", r.Method),
				slog.String("path", r.URL.Path),
				slog.String("host", Host(r)),
				slog.String("controller", controller),
				slog.String("action", actionName),
				slog.Int("status", status),
				slog.Float64("duration", float64(time.Since(start).Microseconds())/1000),
			)
		}()

		if !redirect {
			h.ServeHTTP(rec, r)
			return
		}
		// Rails runs this redirect after verify_authenticity_token and
		// invalidate_session_if_necessary; here it comes first, so a redirected host+path
		// never gets their 422 or /login answers.
		location, err := a.redirects.Location(r)
		switch {
		case err != nil:
			logger.Error("Refusing subdomain redirect", "error", err.Error())
			InternalServerError(rec)
		case location != "":
			rec.Header().Set("Location", location)
			rec.Header().Set("Content-Type", TextHTML)
			// Rack::ETag's default for a response with no ETag, which keeps edges from caching it.
			rec.Header().Set("Cache-Control", "no-cache")
			rec.WriteHeader(http.StatusFound)
		default:
			h.ServeHTTP(rec, r)
		}
	})
}

// setDefaultHeaders covers debug_headers, ActionDispatch::RequestId and SecureHeaders'
// static headers.
func (a *App) setDefaultHeaders(h http.Header, requestID string) {
	h.Set("X-Request-Id", requestID)
	h.Set("X-Revision", a.env.Revision)
	h.Set("X-GR", a.env.GRNum)
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("X-XSS-Protection", "1; mode=block")
	h.Set("X-Download-Options", "noopen")
	h.Set("X-Permitted-Cross-Domain-Policies", "none")
}

// HandleNotFound answers what no pattern matches, a wrong method included, as Rails' router
// would. Without it ServeMux answers with its plain-text 404/405.
func (a *App) HandleNotFound(h http.Handler) {
	a.mux.Handle("/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		a.setDefaultHeaders(w.Header(), requestID(r))
		h.ServeHTTP(w, r)
	}))
}

func (a *App) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	for _, u := range a.unclean {
		if p := r.URL.EscapedPath(); strings.HasPrefix(p, u.prefix) && r.Method != http.MethodConnect && cleanPath(p) != p {
			u.h.ServeHTTP(w, r)
			return
		}
	}
	a.mux.ServeHTTP(w, r)
}

// cleanPath is ServeMux's canonical form of a path, which it redirects any other form to.
func cleanPath(p string) string {
	if p == "" {
		return "/"
	}
	if p[0] != '/' {
		p = "/" + p
	}
	np := path.Clean(p)
	if p[len(p)-1] == '/' && np != "/" {
		if len(p) == len(np)+1 && strings.HasPrefix(p, np) {
			np = p
		} else {
			np += "/"
		}
	}
	return np
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(status int) {
	if s.status == 0 {
		s.status = status
	}
	s.ResponseWriter.WriteHeader(status)
}

func (s *statusRecorder) Write(b []byte) (int, error) {
	if s.status == 0 {
		s.status = http.StatusOK
	}
	return s.ResponseWriter.Write(b)
}

func (s *statusRecorder) Unwrap() http.ResponseWriter {
	return s.ResponseWriter
}
