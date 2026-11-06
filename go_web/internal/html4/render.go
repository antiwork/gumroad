package html4

import "strings"

// RenderChildren is NodeSet#to_html(encoding: "UTF-8") over n's children; on the fragment
// root that is DocumentFragment#to_html, the sanitizer's result. Each child is dumped on its
// own, so the fragment root (which has no name) never gets formatting newlines between them.
func (n *Node) RenderChildren() string {
	var b strings.Builder
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		dump(&b, c, n)
	}
	return b.String()
}

// dump is htmlNodeDumpFormatOutput with format=1, as SaveOptions::DEFAULT_HTML sets.
func dump(b *strings.Builder, cur, parent *Node) {
	switch cur.Type {
	case ElementNode:
		info, known := elemTable[cur.Name]
		b.WriteByte('<')
		b.WriteString(cur.Name)
		for _, a := range cur.Attrs {
			dumpAttr(b, cur, a)
		}
		switch {
		case known && info.empty:
			b.WriteByte('>')
		case cur.FirstChild == nil:
			if known && info.saveEndTag {
				b.WriteByte('>')
			} else {
				b.WriteString("></")
				b.WriteString(cur.Name)
				b.WriteByte('>')
			}
		default:
			b.WriteByte('>')
			// The name[0] test is libxml2's own shortcut for p, pre and param.
			block := known && !info.inline && cur.Name[0] != 'p' && cur.FirstChild != cur.LastChild
			if block && cur.FirstChild.Type != TextNode {
				b.WriteByte('\n')
			}
			for c := cur.FirstChild; c != nil; c = c.NextSibling {
				dump(b, c, cur)
			}
			if block && cur.LastChild.Type != TextNode {
				b.WriteByte('\n')
			}
			b.WriteString("</")
			b.WriteString(cur.Name)
			b.WriteByte('>')
		}
		if known && !info.inline && cur.NextSibling != nil && cur.NextSibling.Type != TextNode &&
			parent != nil && parent.Name != "" && parent.Name[0] != 'p' {
			b.WriteByte('\n')
		}
	case TextNode:
		if parent != nil && (strings.EqualFold(parent.Name, "script") || strings.EqualFold(parent.Name, "style")) {
			b.WriteString(cur.Data)
		} else {
			escape(b, cur.Data)
		}
	case CDATANode:
		b.WriteString(cur.Data)
	case CommentNode:
		b.WriteString("<!--")
		b.WriteString(cur.Data)
		b.WriteString("-->")
	case ProcessingInstructionNode:
		b.WriteString("<?")
		b.WriteString(cur.Name)
		if !cur.NoData {
			b.WriteByte(' ')
			b.WriteString(cur.Data)
		}
		b.WriteByte('>')
	}
}

// dumpAttr is htmlAttrDumpOutput.
func dumpAttr(b *strings.Builder, el *Node, a Attr) {
	b.WriteByte(' ')
	b.WriteString(a.Name)
	if a.Bare || isBooleanAttr(a.Name) {
		return
	}
	value := escapeString(a.Value)
	b.WriteByte('=')
	if strings.EqualFold(a.Name, "href") || strings.EqualFold(a.Name, "action") || strings.EqualFold(a.Name, "src") ||
		strings.EqualFold(a.Name, "name") && strings.EqualFold(el.Name, "a") {
		writeQuoted(b, uriEscape(strings.TrimLeft(value, " \t\n\r")))
		return
	}
	writeQuoted(b, value)
}

// escape is xmlEncodeEntitiesReentrant for an HTML document, with Nokogiri's patches that drop
// the "<!--" and "&{" pass-throughs: <, > and & become entities, other C0 controls than tab,
// LF and CR vanish, and everything else (quotes, non-ASCII) is copied.
func escape(b *strings.Builder, s string) {
	last := 0
	for i := 0; i < len(s); i++ {
		var rep string
		switch c := s[i]; c {
		case '<':
			rep = "&lt;"
		case '>':
			rep = "&gt;"
		case '&':
			rep = "&amp;"
		case '\t', '\n', '\r':
			continue
		default:
			if c >= 0x20 {
				continue
			}
		}
		b.WriteString(s[last:i])
		b.WriteString(rep)
		last = i + 1
	}
	b.WriteString(s[last:])
}

// escapeString is escape returning s itself when nothing changes.
func escapeString(s string) string {
	for i := 0; i < len(s); i++ {
		if c := s[i]; c == '<' || c == '>' || c == '&' || c < 0x20 && c != '\t' && c != '\n' && c != '\r' {
			var b strings.Builder
			b.Grow(len(s) + 8)
			b.WriteString(s[:i])
			escape(&b, s[i:])
			return b.String()
		}
	}
	return s
}

// uriEscape is xmlURIEscapeStr with htmlAttrDumpOutput's list of characters left alone:
// in effect only space, controls and non-ASCII bytes are %-escaped.
func uriEscape(s string) string {
	escapes := 0
	for i := 0; i < len(s); i++ {
		if !isURIKept(s[i]) {
			escapes++
		}
	}
	if escapes == 0 {
		return s
	}
	const hex = "0123456789ABCDEF"
	var b strings.Builder
	b.Grow(len(s) + 2*escapes)
	last := 0
	for i := 0; i < len(s); i++ {
		if c := s[i]; !isURIKept(c) {
			b.WriteString(s[last:i])
			b.WriteByte('%')
			b.WriteByte(hex[c>>4])
			b.WriteByte(hex[c&15])
			last = i + 1
		}
	}
	b.WriteString(s[last:])
	return b.String()
}

func isURIKept(c byte) bool { return c > ' ' && c < 0x7F }

// writeQuoted is xmlOutputBufferWriteQuotedString.
func writeQuoted(b *strings.Builder, s string) {
	switch {
	case !strings.Contains(s, `"`):
		b.WriteByte('"')
		b.WriteString(s)
		b.WriteByte('"')
	case !strings.Contains(s, "'"):
		b.WriteByte('\'')
		b.WriteString(s)
		b.WriteByte('\'')
	default:
		b.WriteByte('"')
		b.WriteString(strings.ReplaceAll(s, `"`, "&quot;"))
		b.WriteByte('"')
	}
}
