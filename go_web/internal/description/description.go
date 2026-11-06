// Package description reproduces what Rails derives from a product's links.description:
// Link#html_safe_description, Link#plaintext_description, the strip_tags snippet that
// Product::StructuredData publishes, and the SnippetText and twitter:description cuts that
// PageMeta::Product applies (rails-html-sanitizer 1.6.2, Loofah 2.25.1, Nokogiri 1.19.3,
// rinku 2.0.6, uri 1.1.1). Inputs it cannot match exactly return ErrUnported so the caller
// can let Rails answer.
package description

import (
	"errors"
	"slices"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/antiwork/gumroad/go_web/internal/csssan"
	"github.com/antiwork/gumroad/go_web/internal/html4"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/rinku"
)

// ErrUnported means the description needs Rails.
var ErrUnported = errors.New("description: input needs Rails")

// Config is the per-environment state the Ruby methods read.
type Config struct {
	// CDNMap is CDN_URL_MAP in insertion order: each origin prefix is gsub'd for its CDN
	// prefix, one after the other.
	CDNMap [][2]string
	// Protocol is PROTOCOL, prefixed to protocol-relative iframe, script and img srcs.
	Protocol string
	// ReviewExists is product_reviews.find_by_external_id(id).present? for a review-card's
	// reviewid ("" when the attribute is missing, which Ruby never finds). Nil sends a
	// description to Rails once the scrub reaches a review-card.
	ReviewExists func(externalID string) (bool, error)
}

const linkAttr = `target="_blank" rel="noopener noreferrer nofollow"`

var allowedElements = setOf("strong", "b", "em", "u", "s", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "code",
	"ul", "ol", "li", "hr", "blockquote", "p", "a", "figure", "figcaption", "img", "div", "span", "iframe", "script",
	"br", "upsell-card", "public-file-embed", "review-card")

var iframeAttributes = setOf("src", "frameborder", "allowfullscreen", "scrolling", "allow", "style")

var upsellCardAttributes = setOf("id", "productid", "variantid", "discount")

var reviewCardAttributes = setOf("reviewid")

// HTML is Link#html_safe_description. present is false where Ruby returns nil, for a
// blank description. An error from c.ReviewExists is returned as is.
func HTML(description string, c Config) (html string, present bool, err error) {
	frag, err := parse(description, c)
	if frag == nil || err != nil {
		return "", false, err
	}
	if html, err = sanitize(frag, c); err != nil {
		return "", false, err
	}
	return html, true, nil
}

// Both is HTML and Plaintext from one parse; each pair is what that function returns.
type Both struct {
	HTML         string
	Present      bool
	HTMLErr      error
	Plaintext    string
	PlaintextErr error
}

// HTMLAndPlaintext is HTML and Plaintext on the same description, parsing it once.
func HTMLAndPlaintext(description string, c Config) Both {
	frag, err := parse(description, c)
	if frag == nil || err != nil {
		return Both{HTMLErr: err, PlaintextErr: err}
	}
	var b Both
	// The scrub mutates the tree, so the text is read first.
	b.Plaintext, b.PlaintextErr = plaintext(frag)
	b.HTML, b.HTMLErr = sanitize(frag, c)
	b.Present = b.HTMLErr == nil
	return b
}

// parse is the CDN-mapped description's fragment, or nil when it is blank.
func parse(description string, c Config) (*html4.Node, error) {
	d, err := cdnMapped(description, c)
	if err != nil || rails.Blank(d) {
		return nil, err
	}
	frag, err := html4.ParseFragment(d)
	if err != nil {
		return nil, ErrUnported
	}
	return frag, nil
}

// sanitize is sanitize(description, scrubber: description_scrubber) then Rinku.auto_link.
func sanitize(frag *html4.Node, c Config) (string, error) {
	s := &scrubber{c: c}
	for _, n := range frag.Children() {
		if err := s.traverse(n); err != nil {
			return "", err
		}
	}
	out, ok := rinku.AutoLink(frag.RenderChildren(), linkAttr)
	if !ok {
		return "", ErrUnported
	}
	return out, nil
}

// cdnMapped is the has_cdn_url reader: replace_s3_urls_with_cdn_urls on the column.
func cdnMapped(description string, c Config) (string, error) {
	// String methods raise on invalid UTF-8 before any of this could run.
	if !utf8.ValidString(description) {
		return "", ErrUnported
	}
	if rails.Blank(description) {
		return description, nil
	}
	for _, m := range c.CDNMap {
		// gsub reads backslash sequences in a String replacement.
		if strings.Contains(m[1], `\`) {
			return "", ErrUnported
		}
		description = strings.ReplaceAll(description, m[0], m[1])
	}
	return description, nil
}

// scrubber is Link#description_scrubber run by Loofah's top-down traversal.
type scrubber struct {
	c Config
	// reviews caches ReviewExists by reviewid for one description.
	reviews    map[string]bool
	styleBytes int
}

// maxStyleBudget bounds the style bytes one description scrubs: CSS scrubbing allocates a
// few hundred bytes per byte.
const maxStyleBudget = 128 << 10

func (s *scrubber) traverse(n *html4.Node) error {
	removed, err := s.scrub(n)
	if err != nil || removed {
		// Ruby still walks a removed node's children, but they are detached: nothing
		// done to them reaches the output.
		return err
	}
	for _, child := range n.Children() {
		if err := s.traverse(child); err != nil {
			return err
		}
	}
	return nil
}

func (s *scrubber) scrub(n *html4.Node) (removed bool, err error) {
	switch n.Type {
	case html4.TextNode:
		// Text takes the scrub_attributes branch, which does nothing to it.
		return false, nil
	case html4.ElementNode:
	case html4.ProcessingInstructionNode:
		// Its name is its target, and one that matches an allowed tag would be scrubbed
		// like an element.
		if allowedElements[n.Name] {
			return false, ErrUnported
		}
		n.Remove()
		return true, nil
	default:
		n.Remove()
		return true, nil
	}
	if !allowedElements[n.Name] {
		n.Remove()
		return true, nil
	}

	switch n.Name {
	case "iframe":
		src, _ := n.Attr("src")
		embeddable, err := embeddableIframe(src)
		if err != nil {
			return false, err
		}
		if !embeddable {
			n.Remove()
			return true, nil
		}
		keepAttributes(n, iframeAttributes)
	case "script":
		src, _ := n.Attr("src")
		iframely, err := iframelyScript(src)
		if err != nil {
			return false, err
		}
		if !iframely {
			n.Remove()
			return true, nil
		}
		if err := s.scrubAttributes(n); err != nil {
			return false, err
		}
	case "upsell-card":
		keepAttributes(n, upsellCardAttributes)
	case "review-card":
		keepAttributes(n, reviewCardAttributes)
		id, _ := n.Attr("reviewid")
		exists, err := s.reviewExists(id)
		if err != nil {
			return false, err
		}
		if !exists {
			n.Remove()
			return true, nil
		}
	default:
		if err := s.scrubAttributes(n); err != nil {
			return false, err
		}
	}

	if n.Name == "iframe" || n.Name == "script" || n.Name == "img" {
		if src, ok := n.Attr("src"); ok && strings.HasPrefix(src, "//") {
			n.SetAttr("src", s.c.Protocol+":"+src)
		}
	}
	return false, nil
}

// maxReviewLookups bounds the queries one description makes; a forged reviewid can decrypt to
// a real id, so distinct strings are not distinct reviews.
const maxReviewLookups = 20

func (s *scrubber) reviewExists(id string) (bool, error) {
	if s.c.ReviewExists == nil {
		return false, ErrUnported
	}
	if exists, ok := s.reviews[id]; ok {
		return exists, nil
	}
	if len(s.reviews) >= maxReviewLookups {
		return false, ErrUnported
	}
	exists, err := s.c.ReviewExists(id)
	if err != nil {
		return false, err
	}
	if s.reviews == nil {
		s.reviews = map[string]bool{}
	}
	s.reviews[id] = exists
	return exists, nil
}

// keepAttributes filters into a new slice: removing one by one is quadratic in the count.
func keepAttributes(n *html4.Node, keep map[string]bool) {
	kept := make([]html4.Attr, 0, len(n.Attrs))
	for _, a := range n.Attrs {
		if keep[a.Name] {
			kept = append(kept, a)
		}
	}
	n.Attrs = kept
}

// embeddableIframe is the iframe test: an iframe.ly host or a Heyzine shelf page.
func embeddableIframe(src string) (bool, error) {
	if rails.Blank(src) {
		return false, nil
	}
	if heyzineShelfEmbedSrc(src) {
		return true, nil
	}
	// The parsed host is a substring of src, and only a trusted host changes the outcome.
	if !strings.Contains(src, "cdn.iframe.ly") && !strings.Contains(src, "iframely.net") {
		return false, nil
	}
	u, ok, err := parseURI(src, "cdn.iframe.ly", "iframely.net")
	return ok && (u.Host == "cdn.iframe.ly" || u.Host == "iframely.net"), err
}

// iframelyScript is the script test: only iframe.ly's embed.js survives.
func iframelyScript(src string) (bool, error) {
	if rails.Blank(src) || !strings.Contains(src, "cdn.iframe.ly") {
		return false, nil
	}
	u, ok, err := parseURI(src, "cdn.iframe.ly")
	return ok && u.Host == "cdn.iframe.ly" && u.Path == "/embed.js", err
}

// parseURI is (URI.parse(src) rescue nil): ok is false for nil. Only http(s) and relative
// URIs stay URI::Generic; another scheme's class may rewrite or reject a URI, which only
// matters when the host is one the scrubber trusts.
func parseURI(src string, trusted ...string) (rails.URI, bool, error) {
	u, err := rails.ParseURI(src)
	if err != nil || !u.HasHost {
		return rails.URI{}, false, nil
	}
	if u.Scheme != "" && u.Scheme != "http" && u.Scheme != "https" && slices.Contains(trusted, u.Host) {
		return rails.URI{}, false, ErrUnported
	}
	return u, true, nil
}

// heyzineShelfEmbedSrc is HEYZINE_SHELF_EMBED_SRC: \Ahttps://heyzine\.com/shelf/[\w-]+\.html\z.
func heyzineShelfEmbedSrc(src string) bool {
	name, ok := strings.CutPrefix(src, "https://heyzine.com/shelf/")
	if !ok {
		return false
	}
	name, ok = strings.CutSuffix(name, ".html")
	return ok && name != "" && strings.IndexFunc(name, func(r rune) bool { return !isWordOrDash(r) }) < 0
}

// isWordOrDash is Onigmo's [\w-]; \w is ASCII-only.
func isWordOrDash(r rune) bool {
	return r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '_' || r == '-'
}

// dataAttribute is DATA_ATTRIBUTE_NAME, /\Adata-[\w-]+\z/.
func dataAttribute(name string) bool {
	rest, ok := strings.CutPrefix(name, "data-")
	return ok && rest != "" && strings.IndexFunc(rest, func(r rune) bool { return !isWordOrDash(r) }) < 0
}

var attributeEscaper = strings.NewReplacer(" ", "%20", `"`, "%22")

// isNotSpace matches /[^[:space:]]/, which is Unicode White_Space.
func isNotSpace(r rune) bool { return !unicode.IsSpace(r) }

// scrubAttributes is Loofah::HTML5::Scrub.scrub_attributes on one of the allowed elements,
// none of which is in SVG_ALLOW_LOCAL_HREF.
func (s *scrubber) scrubAttributes(n *html4.Node) error {
	kept := make([]html4.Attr, 0, len(n.Attrs))
	for _, a := range n.Attrs {
		if !dataAttribute(a.Name) {
			if !csssan.AllowedAttribute(a.Name) {
				continue
			}
			if csssan.AttrValIsURI(a.Name) {
				allowed, err := csssan.AllowedURI(a.Value)
				if err != nil {
					return ErrUnported
				}
				if !allowed {
					continue
				}
			}
			if csssan.SVGAttrValAllowsRef(a.Name) {
				// scrub_attribute_that_allows_local_ref reparses the value with Crass.
				return ErrUnported
			}
		}
		kept = append(kept, a)
	}
	n.Attrs = kept

	if style, ok := n.Attr("style"); ok {
		if s.styleBytes += len(style); s.styleBytes > maxStyleBudget {
			return ErrUnported
		}
		scrubbed, err := csssan.ScrubCSS(style)
		if err != nil {
			return ErrUnported
		}
		n.SetAttr("style", scrubbed)
	}

	// Blank values go, then force_correct_attribute_escaping! runs on what is left.
	kept = make([]html4.Attr, 0, len(n.Attrs))
	for _, a := range n.Attrs {
		if strings.IndexFunc(a.Value, isNotSpace) < 0 && !dataAttribute(a.Name) {
			continue
		}
		if a.Name == "href" || a.Name == "action" || a.Name == "src" || a.Name == "name" && n.Name == "a" {
			a.Value = attributeEscaper.Replace(a.Value)
			a.Bare = false
		}
		kept = append(kept, a)
	}
	n.Attrs = kept
	return nil
}

func setOf(words ...string) map[string]bool {
	set := make(map[string]bool, len(words))
	for _, w := range words {
		set[w] = true
	}
	return set
}
