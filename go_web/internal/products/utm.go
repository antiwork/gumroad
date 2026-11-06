package products

import (
	"context"
	"net/http"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
)

// recordUTMVisitJob is RecordUtmLinkVisitJob's sidekiq_options.
var recordUTMVisitJob = sidekiq.Options{Class: "RecordUtmLinkVisitJob", Queue: "default", Retry: 3}

// utmKeys are track_utm_link_visit's params, the first three required.
var utmKeys = []string{"utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content"}

// maxUTMParamLength is UtmLink::MAX_UTM_PARAM_LENGTH.
const maxUTMParamLength = 200

// utmParams is track_utm_link_visit's utm_params, nil when a required one is blank. reason is a
// value this port leaves to Rails: anything but an ASCII String, whose downcase is Unicode's.
func utmParams(req *rails.Request) (params map[string]any, reason string) {
	for _, key := range utmKeys[:3] {
		if raw, _ := req.Params.Get(key); !rails.Present(raw) {
			return nil, ""
		}
	}
	params = map[string]any{}
	for _, key := range utmKeys {
		raw, _ := req.Params.Get(key)
		if !rails.Present(raw) {
			params[key] = nil
			continue
		}
		s, ok := raw.(string)
		if !ok || !rails.IsASCII(s) {
			return nil, "param " + key
		}
		params[key] = normalizeUTMParam(s)
	}
	return params, ""
}

// normalizeUTMParam is to_s.strip.downcase.gsub(/[^a-z0-9\-_]/u, "-").first(200).presence for an
// ASCII String.
func normalizeUTMParam(s string) any {
	b := []byte(strings.ToLower(rails.Strip(s)))
	for i, c := range b {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			b[i] = '-'
		}
	}
	if len(b) > maxUTMParamLength {
		b = b[:maxUTMParamLength]
	}
	if len(b) == 0 {
		return nil
	}
	return string(b)
}

// trackUTMVisit is track_utm_link_visit for the product's page, which Rails records in the
// request: RecordUtmLinkVisitJob records it the same way. Call it only once nothing will go to
// Rails, which would record it again.
func (h *handler) trackUTMVisit(w http.ResponseWriter, p *page, prod *product) error {
	// cookies[:_gumroad_guid].blank?
	if p.utm == nil || rails.Blank(p.GUID) || p.DryRun {
		return nil
	}
	req := p.Req
	ip, _ := req.RemoteIP()
	var userID any
	// current_user, the visit's and whodunnit's.
	if u := p.Auth.CurrentUser; u != nil {
		userID = u.ID
	}
	visit := map[string]any{
		"seller_id":            p.seller.id,
		"target_resource_type": "product_page",
		"target_resource_id":   prod.id,
		"utm_params":           p.utm,
		"user_id":              userID,
		"referrer":             stringOrNil(req.Referrer()),
		"ip_address":           ip,
		"user_agent":           stringOrNil(req.UserAgent()),
		"browser_guid":         p.GUID,
		"visited_at_us":        req.Now.UnixMicro(),
		"paper_trail": map[string]any{"remote_ip": ip, "request_path": req.Path,
			"request_uuid": w.Header().Get("X-Request-Id")},
	}
	if _, err := h.c.Page.Sidekiq.Push(context.WithoutCancel(p.Ctx), recordUTMVisitJob, visit); err != nil {
		return fallback("utm visit push")
	}
	return nil
}

// stringOrNil is a request reader's String, or nil.
func stringOrNil(s *string) any {
	if s == nil {
		return nil
	}
	return *s
}
