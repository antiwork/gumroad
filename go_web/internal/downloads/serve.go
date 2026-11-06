package downloads

import (
	"net/http"
	"slices"

	"github.com/antiwork/gumroad/go_web/internal/delivery"
	"github.com/antiwork/gumroad/go_web/internal/inertia"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// serve runs ApplicationController's before_actions from redirect_to_custom_subdomain on,
// then the controller's, then the poll. It writes nothing until it knows the outcome, so
// a fallback it returns is still safe.
func (h *handler) serve(w http.ResponseWriter, p *page) error {
	location, err := h.ctl.BeforeActions(p.Visit)
	if err != nil {
		return err
	}
	if location != "" {
		return h.ctl.Redirect(w, p.Visit, location)
	}
	u, path, err := h.checkPermissions(p)
	if err != nil {
		return err
	}
	if path != "" {
		return h.ctl.Redirect(w, p.Visit, path)
	}
	if !p.poll {
		return h.renderPage(w, p, u)
	}
	return h.render(w, p, u)
}

// render is the poll's render(inertia:), set_noindex_header and the after_actions:
// inertia_rails' XSRF-TOKEN cookie, then the flash sweep and the session commit.
func (h *handler) render(w http.ResponseWriter, p *page, u *urlRedirect) error {
	props := rails.NewRHash().Sym("errors", rails.NewRHash())
	requested := rails.Split(p.Req.HTTP.Header.Get("X-Inertia-Partial-Data"), ",")
	audio, locations := slices.Contains(requested, "audio_durations"), slices.Contains(requested, "latest_media_locations")
	var files []delivery.ProductFile
	// latest_media_locations_data returns {} before reading files when there's no purchase,
	// and reading them anyway could raise where Rails doesn't.
	if audio || (locations && p.purchase != nil) {
		var err error
		files, err = delivery.AliveProductFiles(p.Ctx, h.c.DB, u.delivery(), h.c.IDs)
		if err != nil {
			return err
		}
	}
	// requested_download_page_polling_props builds the hash in this order.
	if audio {
		props.Sym("audio_durations", delivery.AudioDurations(files, h.c.IDs))
	}
	if locations {
		var purchaseID *int64
		if p.purchase != nil {
			purchaseID = &p.purchase.id
		}
		// checkPermissions has handed redirects with an installment to Rails.
		positions, err := delivery.LatestMediaLocations(p.Ctx, h.c.DB, purchaseID, false, files, h.c.IDs)
		if err != nil {
			return err
		}
		props.Sym("latest_media_locations", positions)
	}
	props.Sym("_inertia_meta", h.metaTags(p).JSON())
	body := inertia.Page(component, p.Req.FullPath(), props)
	if err := h.finish(w, p); err != nil {
		return err
	}
	rails.RenderInertiaJSON(w, p.Req, body)
	return nil
}

// finish is what follows a render, then set_noindex_header's header.
func (h *handler) finish(w http.ResponseWriter, p *page) error {
	if err := h.ctl.Finish(w, p.Visit); err != nil {
		return err
	}
	w.Header().Set("X-Robots-Tag", "noindex")
	return nil
}
