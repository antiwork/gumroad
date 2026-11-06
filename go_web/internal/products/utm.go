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
// value this port leaves to Rails: anything but a String, whose to_s it doesn't build.
func utmParams(req *rails.Request) (params sidekiq.Hash, reason string) {
	for _, key := range utmKeys[:3] {
		if raw, _ := req.Params.Get(key); !rails.Present(raw) {
			return nil, ""
		}
	}
	params = sidekiq.Hash{}
	for _, key := range utmKeys {
		raw, _ := req.Params.Get(key)
		if !rails.Present(raw) {
			params = append(params, sidekiq.Pair{Key: key, Value: nil})
			continue
		}
		s, ok := raw.(string)
		if !ok {
			return nil, "param " + key
		}
		params = append(params, sidekiq.Pair{Key: key, Value: normalizeUTMParam(s)})
	}
	return params, ""
}

// normalizeUTMParam is to_s.strip.downcase.gsub(/[^a-z0-9\-_]/u, "-").first(200).presence for a
// String: the gsub leaves only ASCII, so the cut counts bytes.
func normalizeUTMParam(s string) any {
	out := strings.Map(func(r rune) rune {
		if r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-' || r == '_' {
			return r
		}
		return '-'
	}, rails.Downcase(rails.Strip(s)))
	if len(out) > maxUTMParamLength {
		out = out[:maxUTMParamLength]
	}
	if out == "" {
		return nil
	}
	return out
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
	visit := sidekiq.Hash{
		{Key: "seller_id", Value: p.seller.id},
		{Key: "target_resource_type", Value: "product_page"},
		{Key: "target_resource_id", Value: prod.id},
		{Key: "utm_params", Value: p.utm},
		{Key: "user_id", Value: userID},
		{Key: "referrer", Value: stringOrNil(req.Referrer())},
		{Key: "ip_address", Value: ip},
		{Key: "user_agent", Value: stringOrNil(req.UserAgent())},
		{Key: "browser_guid", Value: p.GUID},
		{Key: "visited_at_us", Value: req.Now.UnixMicro()},
		{Key: "paper_trail", Value: sidekiq.Hash{{Key: "remote_ip", Value: ip}, {Key: "request_path", Value: req.Path},
			{Key: "request_uuid", Value: w.Header().Get("X-Request-Id")}}},
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
