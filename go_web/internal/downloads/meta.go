package downloads

import "github.com/antiwork/gumroad/go_web/internal/inertia"

// metaTags are the before_actions' meta tags for this request.
func (h *handler) metaTags(p *page) *inertia.MetaTags { return h.ctl.MetaTags(p.Visit) }
