package html4

import (
	"errors"
	"strings"
	"unicode/utf8"
)

// ErrUnported means the input reaches libxml2 behaviour this package does not reproduce; the
// caller must let Rails answer.
var ErrUnported = errors.New("html4: input needs libxml2")

const (
	maxInput = 1 << 20
	// nodePush halts the whole parse past 256 open elements; stay well clear of it.
	maxDepth = 200
	// htmlParseHTMLName stops at HTML_PARSER_BUFFER_SIZE bytes and leaves the rest of the
	// name in the input.
	maxName = 100
)

type elemInfo struct {
	saveEndTag, empty, inline bool
}

type closeKey struct{ old, new string }

// htmlEndPriority: an end tag only closes elements whose priority is not above its own.
func endPriority(name string) int {
	switch name {
	case "div":
		return 150
	case "td", "th":
		return 160
	case "tr":
		return 170
	case "thead", "tbody", "tfoot":
		return 180
	case "table":
		return 190
	case "head", "body":
		return 200
	case "html":
		return 220
	}
	return 100
}

type parser struct {
	s string
	i int
	// stack is both libxml2's name stack and its node stack, which stay in step here.
	stack []*Node
	// pending is the text or CDATA node still being coalesced into buf, as xmlSAX2Text
	// appends to a trailing node of the same type.
	pending *Node
	buf     []byte
	// discarded counts html and head start tags dropped as misplaced (ctxt->depth); while
	// positive, html/body/head end tags are ignored instead of closing body.
	discarded int
	// done is set once body is closed: nothing after it reaches /html/body.
	done bool
	err  error
}

// ParseFragment is Loofah.html4_fragment(input): libxml2 parses "<html><body>" + input
// with Nokogiri's DEFAULT_HTML options and the fragment takes body's children.
func ParseFragment(input string) (*Node, error) {
	if len(input) > maxInput || !utf8.ValidString(input) || strings.IndexByte(input, 0) >= 0 ||
		containsFold(input, "<body") {
		return nil, ErrUnported
	}
	html := &Node{Type: ElementNode, Name: "html"}
	body := &Node{Type: ElementNode, Name: "body"}
	html.appendChild(body)
	p := &parser{s: input, stack: []*Node{html, body}}
	p.parseContent()
	p.flush()
	if p.err != nil {
		return nil, p.err
	}
	frag := &Node{Type: FragmentNode}
	for _, c := range body.Children() {
		c.Remove()
		frag.appendChild(c)
		if c.Type == ElementNode {
			if err := reparentAttrs(c); err != nil {
				return nil, err
			}
		}
	}
	return frag, nil
}

// reparentAttrs is Nokogiri's add_child_node_and_reparent_attrs, run on each node moved into
// the fragment: attributes whose name has a colon are removed and re-set, so they move to the
// end, and a bare one comes back as name="".
func reparentAttrs(n *Node) error {
	if strings.HasPrefix(n.Name, "xml:") {
		// relink_namespace binds the element to the XML namespace.
		return ErrUnported
	}
	var plain, prefixed []Attr
	for _, a := range n.Attrs {
		if !strings.Contains(a.Name, ":") {
			plain = append(plain, a)
			continue
		}
		if strings.HasPrefix(a.Name, "xml:") {
			// xmlSetProp would create a namespaced attribute named after its local part.
			return ErrUnported
		}
		prefixed = append(prefixed, Attr{Name: a.Name, Value: a.Value})
	}
	if prefixed != nil {
		n.Attrs = append(plain, prefixed...)
	}
	return nil
}

func (p *parser) cur() byte {
	if p.i < len(p.s) {
		return p.s[p.i]
	}
	return 0
}

func (p *parser) at(k int) byte {
	if p.i+k < len(p.s) {
		return p.s[p.i+k]
	}
	return 0
}

func (p *parser) name() string {
	if len(p.stack) == 0 {
		return ""
	}
	return p.stack[len(p.stack)-1].Name
}

func (p *parser) pop() { p.stack = p.stack[:len(p.stack)-1] }

func (p *parser) flush() {
	if p.pending != nil {
		p.pending.Data = string(p.buf)
		p.pending = nil
	}
}

func (p *parser) add(n *Node) {
	p.flush()
	p.stack[len(p.stack)-1].appendChild(n)
}

// text is xmlSAX2Text: data joins a trailing node of the same type or starts a new one.
func (p *parser) text(t NodeType, data string) {
	if data == "" {
		return
	}
	if p.pending != nil && p.pending.Type == t && p.stack[len(p.stack)-1].LastChild == p.pending {
		p.buf = append(p.buf, data...)
		return
	}
	n := &Node{Type: t}
	p.add(n)
	p.pending = n
	p.buf = append(p.buf[:0], data...)
}

// parseContent is htmlParseContentInternal entered just after "<html><body>".
func (p *parser) parseContent() {
	currentNode, depth := "body", len(p.stack)
	for p.err == nil && !p.done {
		c := p.cur()
		if c == '<' && p.at(1) == '/' {
			if p.parseEndTag() {
				currentNode, depth = p.name(), len(p.stack)
			}
			continue
		}
		if c == '<' && (isLetter(p.at(1)) || p.at(1) == '_' || p.at(1) == ':') {
			if next := p.lookaheadName(); p.name() != "" && startClose[closeKey{p.name(), next}] {
				p.autoClose(next)
				continue
			}
		}
		if len(p.stack) > 0 && depth >= len(p.stack) && currentNode != p.name() {
			currentNode, depth = p.name(), len(p.stack)
			continue
		}
		switch {
		case c != 0 && (currentNode == "script" || currentNode == "style"):
			p.parseScript()
		case c == '<' && p.at(1) == '!':
			switch {
			case len(p.s)-p.i >= 9 && strings.EqualFold(p.s[p.i+2:p.i+9], "DOCTYPE"):
				// htmlParseDocTypeDecl's quoted literals may hide the closing '>'; not ported.
				p.err = ErrUnported
			case p.at(2) == '-' && p.at(3) == '-':
				p.parseComment()
			default:
				p.skipBogusComment()
			}
		case c == '<' && p.at(1) == '?':
			p.parsePI()
		case c == '<' && isLetter(p.at(1)):
			p.parseElement()
			currentNode, depth = p.name(), len(p.stack)
		case c == '<':
			p.text(TextNode, "<")
			p.i++
		case c == '&':
			p.parseReference()
		case c == 0:
			p.stack = p.stack[:0]
			return
		default:
			p.parseCharData()
		}
	}
}

// htmlAutoClose: a start tag closes every open element htmlStartClose says it ends.
func (p *parser) autoClose(newTag string) {
	for len(p.stack) > 0 && startClose[closeKey{p.name(), newTag}] {
		p.pop()
	}
}

// htmlName is htmlParseHTMLName.
func (p *parser) htmlName() (string, bool) {
	c := p.cur()
	if !isLetter(c) && c != '_' && c != ':' && c != '.' {
		return "", false
	}
	start := p.i
	for p.i-start < maxName {
		c := p.cur()
		if !isLetter(c) && !isDigit(c) && c != ':' && c != '-' && c != '_' && c != '.' {
			break
		}
		p.i++
	}
	return lower(p.s[start:p.i]), true
}

// lookaheadName is htmlParseHTMLName_nonInvasive, which unlike htmlParseHTMLName stops at '.'.
func (p *parser) lookaheadName() string {
	start := p.i + 1
	end := start
	for end-start < maxName && end < len(p.s) {
		c := p.s[end]
		if !isLetter(c) && !isDigit(c) && c != ':' && c != '-' && c != '_' {
			break
		}
		end++
	}
	return lower(p.s[start:end])
}

// parseEndTag is htmlParseEndTag; true means the current element was closed.
func (p *parser) parseEndTag() bool {
	p.i += 2
	name, ok := p.htmlName()
	if !ok {
		return false
	}
	p.skipBlanks()
	if p.cur() != '>' {
		for p.i < len(p.s) && p.s[p.i] != '>' {
			p.i++
		}
	}
	if p.cur() == '>' {
		p.i++
	}
	switch name {
	case "html", "body", "head":
		// head is never open, so only </body> and </html> close anything.
		if p.discarded > 0 {
			p.discarded--
			return false
		}
		if name != "head" {
			p.closeBody()
		}
		return false
	}
	top := len(p.stack) - 1
	at := top
	for at >= 0 && p.stack[at].Name != name {
		at--
	}
	if at < 0 {
		return false
	}
	// htmlAutoCloseOnClose: ignore the tag rather than close a higher-priority element.
	priority := endPriority(name)
	for k := top; k > at; k-- {
		if endPriority(p.stack[k].Name) > priority {
			return false
		}
	}
	p.stack = p.stack[:at]
	return true
}

// parseElement is htmlParseElementInternal with htmlParseStartTag inlined.
func (p *parser) parseElement() {
	p.i++
	name, _ := p.htmlName()
	if name == "body" {
		// Unreachable past ParseFragment's "<body" check, which Nokogiri's path choice needs.
		p.err = ErrUnported
		return
	}
	p.autoClose(name)
	el := &Node{Type: ElementNode, Name: name}
	var seen map[string]bool // only for elements with many attributes
	p.skipBlanks()
	for p.i < len(p.s) && p.s[p.i] != '>' && (p.s[p.i] != '/' || p.at(1) != '>') {
		if attName, ok := p.htmlName(); ok {
			p.skipBlanks()
			a := Attr{Name: attName, Bare: true}
			if p.cur() == '=' {
				p.i++
				p.skipBlanks()
				a = Attr{Name: attName, Value: p.parseAttValue()}
			} else if isBooleanAttr(attName) {
				a = Attr{Name: attName, Value: attName}
			}
			// The first of duplicated attributes wins.
			dup := seen[attName]
			if seen == nil {
				_, dup = el.Attr(attName)
			}
			if !dup {
				el.Attrs = append(el.Attrs, a)
				if seen != nil {
					seen[attName] = true
				} else if len(el.Attrs) > 16 {
					seen = make(map[string]bool)
					for _, a := range el.Attrs {
						seen[a.Name] = true
					}
				}
			}
		} else {
			for p.i < len(p.s) && !isBlank(p.s[p.i]) && p.s[p.i] != '>' && (p.s[p.i] != '/' || p.at(1) != '>') {
				p.i++
			}
		}
		p.skipBlanks()
	}
	if name == "html" || name == "head" {
		p.discardTag()
		return
	}
	if len(p.stack) >= maxDepth {
		p.err = ErrUnported
		return
	}
	p.add(el)
	p.stack = append(p.stack, el)
	switch {
	case p.cur() == '/' && p.at(1) == '>':
		p.i += 2
		p.pop()
	case p.cur() == '>':
		p.i++
		if info, ok := elemTable[name]; ok && info.empty {
			p.pop()
		}
	default:
		// Input ended inside the tag: the element stays, then htmlAutoCloseOnEnd.
		p.stack = p.stack[:0]
	}
}

// discardTag finishes a misplaced html or head start tag. htmlParseElementInternal then
// carries on with the current element's name, so "/>" closes the current element.
func (p *parser) discardTag() {
	p.discarded++
	switch {
	case p.cur() == '/' && p.at(1) == '>':
		p.i += 2
		if p.name() == "body" {
			p.closeBody()
		} else {
			p.pop()
		}
	case p.cur() == '>':
		p.i++
	default:
		p.stack = p.stack[:0]
	}
}

// closeBody ends the parse: later content goes into html or a new html root, never body.
func (p *parser) closeBody() {
	p.stack = p.stack[:0]
	p.done = true
}

// parseAttValue is htmlParseAttValue.
func (p *parser) parseAttValue() string {
	if q := p.cur(); q == '"' || q == '\'' {
		p.i++
		v := p.parseHTMLAttribute(q)
		if p.cur() == q {
			p.i++
		}
		return v
	}
	return p.parseHTMLAttribute(0)
}

// parseHTMLAttribute is htmlParseHTMLAttribute. An invalid character reference writes a NUL
// into the C buffer, so the value ends there although parsing continues to the quote.
func (p *parser) parseHTMLAttribute(stop byte) string {
	start := p.i
	p.skipValueRun(stop)
	if p.cur() != '&' {
		return p.s[start:p.i]
	}
	b := []byte(p.s[start:p.i])
	cut := -1
	for p.cur() == '&' {
		switch {
		case p.at(1) == '#':
			if r := p.parseCharRef(); r != 0 {
				b = utf8.AppendRune(b, r)
			} else if cut < 0 {
				cut = len(b)
			}
		default:
			if r, end, ok := entityAt(p.s, p.i+1); ok {
				b = utf8.AppendRune(b, r)
				p.i = end + 1
			} else {
				b = append(b, '&')
				p.i++
			}
		}
		run := p.i
		p.skipValueRun(stop)
		b = append(b, p.s[run:p.i]...)
	}
	if cut >= 0 {
		b = b[:cut]
	}
	return string(b)
}

// skipValueRun advances over attribute-value bytes up to the next '&' or the value's end.
func (p *parser) skipValueRun(stop byte) {
	for p.i < len(p.s) {
		c := p.s[p.i]
		if c == '&' || c == stop || stop == 0 && (c == '>' || isBlank(c)) {
			return
		}
		p.i++
	}
}

// entityAt matches a known entity name and its ';' at s[i:] the way htmlParseEntityRef does.
// Every other form leaves '&' and the name as literal text, which re-parsing the name as
// ordinary characters reproduces.
func entityAt(s string, i int) (rune, int, bool) {
	if i >= len(s) || !isLetter(s[i]) && s[i] != '_' && s[i] != ':' {
		return 0, 0, false
	}
	end := i + 1
	for end < len(s) && isNameChar(s[end]) {
		end++
	}
	if end < len(s) && s[end] == ';' {
		if r, ok := entities[s[i:end]]; ok {
			return r, end, true
		}
	}
	return 0, 0, false
}

// parseCharRef is htmlParseCharRef; 0 means invalid.
func (p *parser) parseCharRef() rune {
	val := 0
	if x := p.at(2); x == 'x' || x == 'X' {
		p.i += 3
		for p.cur() != ';' {
			d, ok := hexDigit(p.cur())
			if !ok {
				break
			}
			if val < 0x110000 {
				val = val*16 + d
			}
			p.i++
		}
	} else {
		p.i += 2
		for p.cur() != ';' {
			c := p.cur()
			if c < '0' || c > '9' {
				break
			}
			if val < 0x110000 {
				val = val*10 + int(c-'0')
			}
			p.i++
		}
	}
	if p.cur() == ';' {
		p.i++
	}
	if isChar(rune(val)) {
		return rune(val)
	}
	return 0
}

// parseReference is htmlParseReference; an invalid character reference produces nothing.
func (p *parser) parseReference() {
	if p.at(1) == '#' {
		if r := p.parseCharRef(); r != 0 {
			p.text(TextNode, string(r))
		}
		return
	}
	if r, end, ok := entityAt(p.s, p.i+1); ok {
		p.text(TextNode, string(r))
		p.i = end + 1
		return
	}
	p.text(TextNode, "&")
	p.i++
}

// parseCharData is htmlParseCharData. With keepBlanks set and body always open, areBlanks
// and htmlCheckParagraph never change the tree.
func (p *parser) parseCharData() {
	start := p.i
	for p.i < len(p.s) && p.s[p.i] != '<' && p.s[p.i] != '&' {
		p.i++
	}
	p.text(TextNode, dropNonChars(p.s[start:p.i]))
}

// parseScript is htmlParseScript in recovery mode: only "</" plus the element's own name
// ends the raw content.
func (p *parser) parseScript() {
	name := p.name()
	start := p.i
	for p.i < len(p.s) {
		if p.s[p.i] == '<' && p.at(1) == '/' && hasPrefixFold(p.s[p.i+2:], name) {
			break
		}
		p.i++
	}
	p.text(CDATANode, dropNonChars(p.s[start:p.i]))
}

// parseComment is htmlParseComment, including its "<!-->", "<!--->" and "--!>" endings. An
// unterminated comment swallows the rest of the input.
func (p *parser) parseComment() {
	p.i += 4
	q, ql := p.char()
	if q == 0 {
		return
	}
	if q == '>' {
		p.i++
		p.add(&Node{Type: CommentNode})
		return
	}
	p.i += ql
	r, rl := p.char()
	if r == 0 {
		return
	}
	if q == '-' && r == '>' {
		p.i++
		p.add(&Node{Type: CommentNode})
		return
	}
	p.i += rl
	var buf []byte
	cur, l := p.char()
	for cur != 0 && (cur != '>' || r != '-' || q != '-') {
		p.i += l
		next, nl := p.char()
		if q == '-' && r == '-' && cur == '!' && next == '>' {
			cur = '>'
			break
		}
		if isChar(q) {
			buf = utf8.AppendRune(buf, q)
		}
		q, r = r, cur
		cur, l = next, nl
	}
	if cur != '>' {
		return
	}
	p.i++
	p.add(&Node{Type: CommentNode, Data: string(buf)})
}

// char decodes the rune at the cursor; 0 at the end of input (the input has no NULs).
func (p *parser) char() (rune, int) {
	if p.i >= len(p.s) {
		return 0, 0
	}
	if c := p.s[p.i]; c < utf8.RuneSelf {
		return rune(c), 1
	}
	return utf8.DecodeRuneInString(p.s[p.i:])
}

// skipBogusComment is htmlSkipBogusComment: "<!" not starting a comment or DOCTYPE is
// dropped through the next '>'.
func (p *parser) skipBogusComment() {
	for p.i < len(p.s) {
		c := p.s[p.i]
		p.i++
		if c == '>' {
			return
		}
	}
}

// parsePI is htmlParsePI. A target htmlParseName rejects leaves "<?" consumed and nothing else.
func (p *parser) parsePI() {
	p.i += 2
	start := p.i
	c := p.cur()
	if c >= utf8.RuneSelf {
		// htmlParseNameComplex and its Unicode name tables.
		p.err = ErrUnported
		return
	}
	if !isLetter(c) && c != '_' && c != ':' {
		return
	}
	end := start + 1
	for end < len(p.s) && isNameChar(p.s[end]) {
		end++
	}
	if end == len(p.s) {
		return
	}
	if p.s[end] >= utf8.RuneSelf {
		p.err = ErrUnported
		return
	}
	target := p.s[start:end]
	p.i = end
	if p.cur() == '>' {
		p.i++
		p.add(&Node{Type: ProcessingInstructionNode, Name: target, NoData: true})
		return
	}
	p.skipBlanks()
	dataStart := p.i
	for p.i < len(p.s) && p.s[p.i] != '>' {
		p.i++
	}
	if p.i == len(p.s) {
		return
	}
	data := dropNonChars(p.s[dataStart:p.i])
	p.i++
	p.add(&Node{Type: ProcessingInstructionNode, Name: target, Data: data})
}

func (p *parser) skipBlanks() {
	for p.i < len(p.s) && isBlank(p.s[p.i]) {
		p.i++
	}
}

// dropNonChars removes what IS_CHAR rejects: C0 controls other than tab, LF and CR, and
// U+FFFE/U+FFFF. Surrogates and NULs cannot reach here.
func dropNonChars(s string) string {
	clean := true
	for i := 0; i < len(s); i++ {
		if c := s[i]; c < 0x20 && c != '\t' && c != '\n' && c != '\r' || c == 0xEF && isNonCharTail(s, i) {
			clean = false
			break
		}
	}
	if clean {
		return s
	}
	b := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < 0x20 && c != '\t' && c != '\n' && c != '\r' {
			continue
		}
		if c == 0xEF && isNonCharTail(s, i) {
			i += 2
			continue
		}
		b = append(b, c)
	}
	return string(b)
}

func isNonCharTail(s string, i int) bool {
	return i+2 < len(s) && s[i+1] == 0xBF && (s[i+2] == 0xBE || s[i+2] == 0xBF)
}

func isChar(r rune) bool {
	switch {
	case r < 0x20:
		return r == '\t' || r == '\n' || r == '\r'
	case r <= 0xD7FF:
		return true
	case r < 0xE000:
		return false
	case r <= 0xFFFD:
		return true
	}
	return r >= 0x10000 && r <= 0x10FFFF
}

func isLetter(c byte) bool { return c|0x20 >= 'a' && c|0x20 <= 'z' }
func isDigit(c byte) bool  { return c >= '0' && c <= '9' }
func isBlank(c byte) bool  { return c == ' ' || c == '\t' || c == '\n' || c == '\r' }

// isNameChar is the ASCII accelerator of htmlParseName.
func isNameChar(c byte) bool {
	return isLetter(c) || isDigit(c) || c == '_' || c == '-' || c == ':' || c == '.'
}

func hexDigit(c byte) (int, bool) {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0'), true
	case c >= 'a' && c <= 'f':
		return int(c-'a') + 10, true
	case c >= 'A' && c <= 'F':
		return int(c-'A') + 10, true
	}
	return 0, false
}

func isBooleanAttr(name string) bool {
	switch strings.ToLower(name) {
	case "checked", "compact", "declare", "defer", "disabled", "ismap", "multiple", "nohref",
		"noresize", "noshade", "nowrap", "readonly", "selected":
		return true
	}
	return false
}

func lower(s string) string {
	for i := 0; i < len(s); i++ {
		if c := s[i]; c >= 'A' && c <= 'Z' {
			return strings.ToLower(s)
		}
	}
	return s
}

func hasPrefixFold(s, prefix string) bool {
	return len(s) >= len(prefix) && strings.EqualFold(s[:len(prefix)], prefix)
}

// containsFold reports whether s contains the ASCII string sub, ignoring ASCII case.
func containsFold(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i] == sub[0] && hasPrefixFold(s[i:], sub) {
			return true
		}
	}
	return false
}
