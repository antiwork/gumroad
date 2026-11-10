package errorreport

import (
	"log/slog"

	"github.com/getsentry/sentry-go"
)

func NewHandlerWithHub(next slog.Handler, hub *sentry.Hub) *Handler {
	return &Handler{next: next, hub: hub}
}
