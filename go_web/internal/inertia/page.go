package inertia

import "github.com/antiwork/gumroad/go_web/internal/rails"

// Page is the page object Renderer#page builds, as JSON: no version is configured, and
// history is neither encrypted nor cleared.
func Page(component, url string, props *rails.RHash) string {
	return rails.EncodeJSON(rails.NewRHash().
		Sym("component", component).
		Sym("props", props).
		Sym("url", url).
		Sym("version", nil).
		Sym("encryptHistory", false).
		Sym("clearHistory", false))
}
