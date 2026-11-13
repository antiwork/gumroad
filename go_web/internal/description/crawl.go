package description

import (
	"regexp"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/html4"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// loofahAllowed is Loofah::HTML5::SafeList::ALLOWED_ELEMENTS_WITH_LIBXML2 as the HTML4 parser
// names elements, lowercased.
var loofahAllowed = setOf("a", "abbr", "acronym", "address", "altglyph", "animate", "animatecolor", "animatemotion",
	"animatetransform", "annotation", "annotation-xml", "area", "article", "aside", "audio", "b", "bdi", "bdo", "big",
	"blockquote", "body", "br", "button", "canvas", "caption", "center", "circle", "cite", "clippath", "code", "col",
	"colgroup", "command", "cursor", "datalist", "dd", "defs", "del", "desc", "details", "dfn", "dir", "div", "dl", "dt",
	"ellipse", "em", "fegaussianblur", "feimage", "fieldset", "figcaption", "figure", "filter", "font", "font-face",
	"font-face-name", "font-face-src", "footer", "foreignobject", "form", "g", "glyph", "h1", "h2", "h3", "h4", "h5", "h6",
	"head", "header", "hkern", "hr", "html", "i", "img", "input", "ins", "kbd", "label", "legend", "li", "line",
	"lineargradient", "maction", "main", "map", "mark", "marker", "mask", "math", "menclose", "menu", "merror", "metadata",
	"meter", "mfenced", "mfrac", "mi", "missing-glyph", "mmultiscripts", "mn", "mo", "mover", "mpadded", "mpath", "mphantom",
	"mprescripts", "mroot", "mrow", "ms", "mspace", "msqrt", "mstyle", "msub", "msubsup", "msup", "mtable", "mtd", "mtext",
	"mtr", "munder", "munderover", "nav", "none", "ol", "optgroup", "option", "output", "p", "path", "pattern", "polygon",
	"polyline", "pre", "q", "radialgradient", "rect", "s", "samp", "section", "select", "semantics", "set", "small", "span",
	"stop", "strike", "strong", "sub", "summary", "sup", "svg", "switch", "symbol", "table", "tbody", "td", "text", "textpath",
	"textarea", "tfoot", "th", "thead", "time", "title", "tr", "tref", "tspan", "tt", "u", "ul", "use", "var", "video", "wbr")

// extraneousNewlines is Loofah.remove_extraneous_whitespace's /\n\s*\n\s*\n/, where Ruby's \s
// has \v and Go's doesn't.
var extraneousNewlines = regexp.MustCompile("\n[ \t\n\v\f\r]*\n[ \t\n\v\f\r]*\n")

// CrawlText is the product page crawl fallback's copy of a sanitized description:
// Loofah.fragment(html).scrub!(:prune).to_text(encode_special_chars: false).strip. The prune
// drops every element Loofah doesn't allow with all it holds, comments included.
func CrawlText(html string) (string, error) {
	if html == "" {
		return "", nil
	}
	frag, err := html4.ParseFragment(html)
	if err != nil {
		return "", ErrUnported
	}
	var b strings.Builder
	for _, n := range frag.Children() {
		if err := writePrunedContent(&b, n); err != nil {
			return "", err
		}
	}
	// String#strip: NULs and ASCII whitespace, at either end.
	return strings.Trim(extraneousNewlines.ReplaceAllString(b.String(), "\n\n"), "\x00\t\n\v\f\r "), nil
}

// writePrunedContent is writeContent over what the prune keeps.
func writePrunedContent(b *strings.Builder, n *html4.Node) error {
	switch n.Type {
	case html4.TextNode:
		b.WriteString(n.Data)
	case html4.CDATANode:
		// The prune escapes a CDATA node it keeps. Only script and style hold one, and both go.
		return ErrUnported
	case html4.ElementNode:
		if !loofahAllowed[n.Name] {
			return nil
		}
		if n.Name == "br" {
			b.WriteByte('\n')
			return nil
		}
		block := lineBreakers[n.Name]
		if block {
			b.WriteByte('\n')
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			if err := writePrunedContent(b, c); err != nil {
				return err
			}
		}
		if block {
			b.WriteByte('\n')
		}
	}
	return nil
}

// Paragraphs is simple_format for text that is already safe HTML: each run of text between
// blank lines in a <p>, a lone newline followed by a <br />, and "<p></p>" for blank text.
func Paragraphs(s string) string {
	if rails.Blank(s) {
		return "<p></p>"
	}
	s = strings.ReplaceAll(strings.ReplaceAll(s, "\r\n", "\n"), "\r", "\n")
	var b strings.Builder
	b.Grow(len(s) + 16)
	for i, p := range splitParagraphs(s) {
		if i > 0 {
			b.WriteString("\n\n")
		}
		b.WriteString("<p>")
		// No paragraph holds "\n\n", so a newline with text on both sides is /([^\n]\n)(?=[^\n])/.
		for j := 0; j < len(p); j++ {
			b.WriteByte(p[j])
			if p[j] == '\n' && j > 0 && j < len(p)-1 {
				b.WriteString("<br />")
			}
		}
		b.WriteString("</p>")
	}
	return b.String()
}

// splitParagraphs is String#split(/\n\n+/): a leading empty piece stays, trailing ones go.
func splitParagraphs(s string) []string {
	var out []string
	start := 0
	for i := 0; i < len(s); {
		if s[i] == '\n' && i+1 < len(s) && s[i+1] == '\n' {
			out = append(out, s[start:i])
			for i < len(s) && s[i] == '\n' {
				i++
			}
			start = i
			continue
		}
		i++
	}
	out = append(out, s[start:])
	for len(out) > 0 && out[len(out)-1] == "" {
		out = out[:len(out)-1]
	}
	return out
}
