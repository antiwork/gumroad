package description

import (
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/antiwork/gumroad/go_web/internal/html4"
)

// Loofah::Elements::LINEBREAKERS: to_text puts newlines around these, and one for a br.
var lineBreakers = setOf("address", "article", "aside", "blockquote", "br", "canvas", "center", "dd", "dir", "div",
	"dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "frameset", "h1", "h2", "h3", "h4", "h5", "h6",
	"header", "hgroup", "hr", "isindex", "li", "main", "menu", "nav", "noframes", "noscript", "ol", "output", "p",
	"pre", "section", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul", "video")

// Plaintext is Link#plaintext_description: Loofah's to_text(encode_special_chars: false),
// squished. Comments drop out; script and style content stays in.
func Plaintext(description string, c Config) (string, error) {
	frag, err := parse(description, c)
	if frag == nil || err != nil {
		return "", err
	}
	return plaintext(frag)
}

func plaintext(frag *html4.Node) (string, error) {
	var b strings.Builder
	for _, n := range frag.Children() {
		if n.Type == html4.ProcessingInstructionNode && !lineBreakers[n.Name] {
			// Only a top-level one's content is read: Node#content of an element skips it.
			b.WriteString(n.Data)
			continue
		}
		if err := writeContent(&b, n); err != nil {
			return "", err
		}
	}
	return Squish(b.String()), nil
}

// writeContent is Node#content after the newline_block_elements scrub, which replaces each
// line breaker with a text node of its content between newlines (just "\n" for a br).
func writeContent(b *strings.Builder, n *html4.Node) error {
	switch n.Type {
	case html4.TextNode, html4.CDATANode:
		b.WriteString(n.Data)
	case html4.ProcessingInstructionNode:
		if lineBreakers[n.Name] {
			return ErrUnported
		}
	case html4.ElementNode:
		if n.Name == "br" {
			b.WriteByte('\n')
			return nil
		}
		block := lineBreakers[n.Name]
		if block {
			b.WriteByte('\n')
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			if err := writeContent(b, c); err != nil {
				return err
			}
		}
		if block {
			b.WriteByte('\n')
		}
	}
	return nil
}

// StripTagsSquished is strip_tags(html).to_s.squish under Rails::HTML4::FullSanitizer:
// the text nodes of the reparsed html, entity-escaped again, squished.
func StripTagsSquished(html string) (string, error) {
	if html == "" {
		return "", nil
	}
	frag, err := html4.ParseFragment(html)
	if err != nil {
		return "", ErrUnported
	}
	var text strings.Builder
	var walk func(*html4.Node)
	walk = func(n *html4.Node) {
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			if c.Type == html4.TextNode {
				text.WriteString(c.Data)
			}
			walk(c)
		}
	}
	walk(frag)
	// TextOnlyScrubber leaves only the text nodes, at the root, and each escapes on its own.
	return Squish(html4.EscapeText(text.String())), nil
}

// Squish is ActiveSupport's String#squish: runs of [[:space:]] (Unicode White_Space) become
// one space, then String#strip, which also drops NULs at either end.
func Squish(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	space := false
	for _, r := range s {
		if unicode.IsSpace(r) {
			space = true
			continue
		}
		if space {
			b.WriteByte(' ')
			space = false
		}
		b.WriteRune(r)
	}
	if space {
		b.WriteByte(' ')
	}
	return strings.Trim(b.String(), " \x00")
}

const (
	snippetMaxLength = 160
	snippetOmission  = "..."
	// SnippetText::TRAILING_PUNCTUATION, /[.,;:!?…]+\z/.
	snippetTrailingPunctuation = ".,;:!?…"

	twitterDescriptionMaxLength = 200
	twitterDescriptionKeep      = 197
)

// Snippet is SnippetText.truncate(text): at most 160 characters, cut at the last space
// that leaves room for "...". text must be valid UTF-8, as every output of this package is.
func Snippet(text string) string {
	if utf8.RuneCountInString(text) <= snippetMaxLength {
		return text
	}
	// String#truncate(157, separator: " ", omission: ""): rindex(" ", 157) or 157 characters.
	room := snippetMaxLength - len(snippetOmission)
	stop := charOffset(text, room)
	if i := strings.LastIndexByte(text[:stop+1], ' '); i >= 0 {
		stop = i
	}
	return strings.TrimRight(text[:stop], snippetTrailingPunctuation) + snippetOmission
}

// TwitterDescription is PageMeta::Product's twitter:description cut: past 200 characters,
// the first 197 and "...".
func TwitterDescription(s string) string {
	if utf8.RuneCountInString(s) <= twitterDescriptionMaxLength {
		return s
	}
	return s[:charOffset(s, twitterDescriptionKeep)] + "..."
}

// charOffset returns the byte offset of the nth character of s, which has more than n.
func charOffset(s string, n int) int {
	for i := range s {
		if n == 0 {
			return i
		}
		n--
	}
	return len(s)
}
