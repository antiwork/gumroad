package inertia

import (
	"fmt"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/vite"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

// LayoutConfig is what layouts/inertia.html.erb and layouts/application/_head.html.erb
// read from config.
type LayoutConfig struct {
	// FACEBOOK_OG_NAMESPACE.
	OGNamespace string
	// DNSPrefetch is the ones of config.asset_host, CDN_S3_PROXY_HOST and
	// PUBLIC_STORAGE_CDN_S3_PROXY_HOST that aren't nil. "" is rendered, as Ruby does.
	DNSPrefetch []string
	// ActionCableURL is config.action_cable.url.
	ActionCableURL string
	Manifest       *vite.Manifest
}

// Layout is the inertia layout for a page that leaves @body_id, @body_class, @hide_styles
// and @hide_layouts unset and has no content_for blocks. Everything but the request's
// parts is rendered once.
type Layout struct {
	head, tail, link string
	manifest         *vite.Manifest
}

// NewLayout renders the layout's fixed parts. The Vite entrypoints must be in the manifest.
func NewLayout(c LayoutConfig) (*Layout, error) {
	stylesheet, err := c.Manifest.EntrypointStylesheet("design")
	if err != nil {
		return nil, err
	}
	script, err := c.Manifest.TypescriptTag("base")
	if err != nil {
		return nil, err
	}

	var head strings.Builder
	ns := web.HTMLEscape(c.OGNamespace)
	head.WriteString("<!DOCTYPE html>\n<html lang=\"en\">\n")
	head.WriteString(`  <head prefix="og: http://ogp.me/ns# fb: http://ogp.me/ns/fb# ` + ns + `: http://ogp.me/ns/fb/` + ns + "#\">\n")
	for _, u := range c.DNSPrefetch {
		host, ok := rails.URIHost(u)
		if !ok {
			return nil, fmt.Errorf("URI.parse raises on %q", u)
		}
		head.WriteString(`    <link rel="dns-prefetch" href="` + web.HTMLEscape("//"+host) + "\">\n")
	}
	head.WriteString(`  <meta name="action-cable-url" content="` + web.HTMLEscape(c.ActionCableURL) + "\" />\n")
	// vite_client_tag and vite_react_refresh_tag render nothing without a dev server.
	head.WriteString("  \n  \n")
	head.WriteString("  " + stylesheet.HTML + "\n")
	// yield :style and :smart_app_banner, then the meta tags' indent.
	head.WriteString("  \n  \n  ")

	// yield :script follows the script tag.
	tail := "\n\n      " + script.HTML + "\n    \n  </body>\n</html>\n"
	// The head renders before the body, so its stylesheet's link comes first.
	return &Layout{head: head.String(), tail: tail, link: vite.LinkHeader(stylesheet, script), manifest: c.Manifest}, nil
}

// Manifest is the layout's Vite manifest, for resolving other entrypoints once at startup.
func (l *Layout) Manifest() *vite.Manifest { return l.manifest }

// LinkHeader is the Link header the asset tags add to every render.
func (l *Layout) LinkHeader() string { return l.link }

// Document is one render's part of the layout.
type Document struct {
	// Component, URL and Props make the page object. Render adds Meta to Props as
	// _inertia_meta, so the head and the page carry the same tags.
	Component, URL string
	Props          *rails.RHash
	Meta           *MetaTags
	// UserAgent is the User-Agent header, and AsEmbed whether params[:as_embed] is truthy.
	UserAgent string
	AsEmbed   bool
	// BodyID is @body_id, and BodyClass @body_class.
	BodyID, BodyClass string
	// DesignSettings and UserAgentInfo are the JSON the layout writes into its hidden divs.
	DesignSettings, UserAgentInfo string
}

// PageJSON is the page object, with the meta tags among its props.
func (d Document) PageJSON() string {
	return Page(d.Component, d.URL, d.Props.Sym("_inertia_meta", d.Meta.JSON()))
}

// Render returns the page's HTML.
func (l *Layout) Render(d Document) string {
	page := d.PageJSON()
	var b strings.Builder
	// Escaping a quote takes six bytes, and the page JSON is most of the document.
	b.Grow(len(l.head) + len(l.tail) + 2*len(page) + 4096)
	b.WriteString(l.head)
	d.Meta.writeHTML(&b)
	b.WriteString("\n</head>\n\n")

	class := "group/body"
	if strings.Contains(d.UserAgent, "Macintosh") {
		class += " mac"
	}
	if d.BodyClass != "" {
		class += " " + d.BodyClass
	}
	style := ""
	if d.AsEmbed {
		style = "background: transparent"
	}
	b.WriteString(`  <body id="`)
	web.WriteHTMLEscaped(&b, d.BodyID)
	b.WriteString(`" class="`)
	web.WriteHTMLEscaped(&b, class)
	b.WriteString(`" style="` + style + "\">\n")
	b.WriteString(`    <div id="design-settings" data-settings="`)
	web.WriteHTMLEscaped(&b, d.DesignSettings)
	b.WriteString("\" style=\"display: none;\"></div>\n" + `    <div id="user-agent-info" data-settings="`)
	web.WriteHTMLEscaped(&b, d.UserAgentInfo)
	b.WriteString("\" style=\"display: none;\"></div>\n")
	// The flash partial renders nothing for Inertia, and there are no discover SEO links.
	b.WriteString("    \n    \n" + `    <div id="app" data-page="`)
	web.WriteHTMLEscaped(&b, page)
	b.WriteString(`"></div>`)
	b.WriteString(l.tail)
	return b.String()
}

// HTML is inertia_meta_tags: each tag's to_tag, one per line.
func (m *MetaTags) HTML() string {
	var b strings.Builder
	m.writeHTML(&b)
	return b.String()
}

func (m *MetaTags) writeHTML(b *strings.Builder) {
	for i, k := range m.keys {
		if i > 0 {
			b.WriteByte('\n')
		}
		m.tags[k].writeHTML(b)
	}
}

// unaryTags is InertiaRails::MetaTag::UNARY_TAGS.
var unaryTags = map[string]bool{
	"area": true, "base": true, "br": true, "col": true, "embed": true, "hr": true, "img": true, "input": true,
	"keygen": true, "link": true, "meta": true, "source": true, "track": true, "wbr": true,
}

// writeHTML is MetaTag#to_tag: the data, then type and inertia, with underscores in keys
// made dashes. An empty type is nil's, the only one set_meta_tag passes here.
func (t MetaTag) writeHTML(b *strings.Builder) {
	b.WriteString("<" + t.tagName)
	attr := func(k, v string) {
		b.WriteString(" " + strings.ReplaceAll(k, "_", "-") + `="`)
		web.WriteHTMLEscaped(b, v)
		b.WriteByte('"')
	}
	var inner Attr
	for _, a := range t.data {
		if a.Key == "inner_content" {
			inner = a
			continue
		}
		attr(a.Key, a.Value)
	}
	// The tag builder drops a nil type.
	if t.typ != "" {
		attr("type", t.typ)
	}
	attr("inertia", t.headKey)
	b.WriteByte('>')
	if !unaryTags[t.tagName] {
		switch {
		case t.tagName == "script" && inner.JSON != nil:
			// tag_script_inner_content: json_escape(to_json), which EncodeJSON's escaping covers.
			b.WriteString(rails.EncodeJSON(inner.JSON))
		case inner.Raw:
			b.WriteString(inner.Value)
		default:
			web.WriteHTMLEscaped(b, inner.Value)
		}
		b.WriteString("</" + t.tagName + ">")
	}
}
