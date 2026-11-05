package downloads

import (
	"github.com/antiwork/gumroad/go_web/internal/inertia"
	"github.com/antiwork/gumroad/go_web/internal/session"
)

// metaTags are the before_actions' meta tags for this request.
func (h *handler) metaTags(p *page) *inertia.MetaTags {
	// prepare has checked the token decodes.
	masked, _ := session.MaskedGlobalToken(p.csrf)
	v := inertia.Viewer{CSRFToken: masked}
	if seller := p.auth.CurrentSeller; seller != nil {
		v.HasSeller, v.SellerDisablesAnalytics = true, seller.DisableThirdPartyAnalytics()
	}
	if logged := p.auth.LoggedInUser(); logged != nil {
		v.LoggedInUserID = logged.ExternalID
	}
	return h.c.Meta.Tags(v)
}
