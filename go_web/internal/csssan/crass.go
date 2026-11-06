package csssan

import (
	"strings"
	"unicode/utf8"
)

// The parts of crass 1.0.6 that Crass.parse_properties and Crass::Parser.stringify use.
// Crass::Scanner counts characters, not bytes, so this works on runes.

const eof = -1

// Ruby raises SystemStackError a few thousand levels deep (each nested block, and each
// comment directly after another, is a recursive call), and Integer#** with an exponent in
// the millions takes seconds. These sit far below either.
const (
	maxNesting      = 128
	maxCommentRun   = 256
	maxNumberDigits = 10000
	maxExponent     = 10000
)

type kind uint8

const (
	tokWhitespace kind = iota
	tokIdent
	tokFunction
	tokAtKeyword
	tokHash
	tokString
	tokBadString
	tokURL
	tokBadURL
	tokDelim
	tokNumber
	tokPercentage
	tokDimension
	tokUnicodeRange
	tokMatch // include, dash, prefix, suffix and substring match, and column
	tokCDO
	tokCDC
	tokColon
	tokSemicolon
	tokComma
	tokOpenParen
	tokCloseParen
	tokOpenSquare
	tokCloseSquare
	tokOpenCurly
	tokCloseCurly
)

type token struct {
	kind kind
	raw  string
	// The unescaped name of an ident, function or at-keyword, or a delim's character.
	value string
}

type tokenizer struct {
	s      []rune
	pos    int
	mark   int
	cur    rune
	hasCur bool // Scanner#current is nil before the first character
	err    error
}

func tokenize(input string) ([]token, error) {
	z := tokenizer{s: []rune(preprocess.Replace(input))}
	var toks []token
	for {
		t, ok := z.next()
		if z.err != nil {
			return nil, z.err
		}
		if !ok {
			return toks, nil
		}
		toks = append(toks, t)
	}
}

var preprocess = strings.NewReplacer("\r\n", "\n", "\r", "\n", "\f", "\n", "\x00", "\uFFFD")

func (z *tokenizer) peek(i int) rune {
	if z.pos+i < len(z.s) {
		return z.s[z.pos+i]
	}
	return eof
}

// consume returns eof at the end without touching current, like Scanner#consume.
func (z *tokenizer) consume() rune {
	if z.pos < len(z.s) {
		z.cur, z.hasCur = z.s[z.pos], true
		z.pos++
		return z.cur
	}
	return eof
}

func (z *tokenizer) reconsume() {
	if z.pos > 0 {
		z.pos--
	}
}

// current is Scanner#current, which the no-argument predicates read. Ruby raises on nil.
func (z *tokenizer) current() rune {
	if !z.hasCur {
		z.err = ErrUnported
	}
	return z.cur
}

func (z *tokenizer) scanWhile(f func(rune) bool) int {
	n := 0
	for z.pos < len(z.s) && f(z.s[z.pos]) {
		z.pos++
		n++
	}
	if n > 0 {
		z.cur, z.hasCur = z.s[z.pos-1], true
	}
	return n
}

func (z *tokenizer) token(k kind, value string) token {
	return token{kind: k, raw: string(z.s[z.mark:z.pos]), value: value}
}

func (z *tokenizer) next() (token, bool) {
	// Comments are dropped: Tokenizer#consume recurses past each one.
	for run := 0; ; run++ {
		if z.pos == len(z.s) {
			return token{}, false
		}
		z.mark = z.pos
		if z.peek(0) != '/' || z.peek(1) != '*' {
			break
		}
		if run == maxCommentRun {
			z.err = ErrUnported
			return token{}, false
		}
		z.consumeComment()
	}

	if z.scanWhile(isWhitespace) > 0 {
		return z.token(tokWhitespace, ""), true
	}

	c := z.consume()
	p0, p1, p2 := z.peek(0), z.peek(1), z.peek(2)
	switch c {
	case '"', '\'':
		return z.consumeString(c), true
	case '#':
		if isName(p0) || validEscape(p0, p1) {
			name := z.consumeName()
			return z.token(tokHash, name), true
		}
	case '$', '*', '^', '~':
		if p0 == '=' {
			z.consume()
			return z.token(tokMatch, ""), true
		}
	case '(':
		return z.token(tokOpenParen, ""), true
	case ')':
		return z.token(tokCloseParen, ""), true
	case '+', '.':
		if startNumber(c, p0, p1) {
			z.reconsume()
			return z.consumeNumeric(), true
		}
	case ',':
		return z.token(tokComma, ""), true
	case '-':
		switch {
		case startNumber(c, p0, p1):
			z.reconsume()
			return z.consumeNumeric(), true
		case p0 == '-' && p1 == '>':
			z.consume()
			z.consume()
			return z.token(tokCDC, ""), true
		case startIdentifier(c, p0, p1):
			z.reconsume()
			return z.consumeIdent(), true
		}
	case ':':
		return z.token(tokColon, ""), true
	case ';':
		return z.token(tokSemicolon, ""), true
	case '<':
		if p0 == '!' && p1 == '-' && p2 == '-' {
			z.consume()
			z.consume()
			z.consume()
			return z.token(tokCDO, ""), true
		}
	case '@':
		if startIdentifier(p0, p1, p2) {
			name := z.consumeName()
			return z.token(tokAtKeyword, name), true
		}
	case '[':
		return z.token(tokOpenSquare, ""), true
	case ']':
		return z.token(tokCloseSquare, ""), true
	case '{':
		return z.token(tokOpenCurly, ""), true
	case '}':
		return z.token(tokCloseCurly, ""), true
	case '\\':
		if validEscape(c, p0) {
			z.reconsume()
			return z.consumeIdent(), true
		}
	case 'U', 'u':
		if p0 == '+' && (isHex(p1) || p1 == '?') {
			z.consume()
			return z.consumeUnicodeRange(), true
		}
		z.reconsume()
		return z.consumeIdent(), true
	case '|':
		if p0 == '=' || p0 == '|' {
			z.consume()
			return z.token(tokMatch, ""), true
		}
	default:
		if isDigit(c) {
			z.reconsume()
			return z.consumeNumeric(), true
		}
		if isNameStart(c) {
			z.reconsume()
			return z.consumeIdent(), true
		}
	}
	return z.token(tokDelim, string(c)), true
}

func (z *tokenizer) consumeComment() {
	z.consume()
	z.consume()
	for i := z.pos; i+1 < len(z.s); i++ {
		if z.s[i] == '*' && z.s[i+1] == '/' {
			z.pos = i + 2
			z.cur, z.hasCur = '/', true
			return
		}
	}
	// Scanner#consume_rest leaves current nil when nothing is left.
	z.hasCur = z.pos < len(z.s)
	if z.hasCur {
		z.cur = z.s[len(z.s)-1]
	}
	z.pos = len(z.s)
}

func (z *tokenizer) consumeEscaped() rune {
	if z.pos == len(z.s) {
		return utf8.RuneError
	}
	if !isHex(z.peek(0)) {
		return z.consume()
	}
	cp := 0
	for n := 0; n < 6 && isHex(z.peek(0)); n++ {
		cp = cp<<4 | hexValue(z.consume())
	}
	if isWhitespace(z.peek(0)) {
		z.consume()
	}
	if cp == 0 || cp >= 0xD800 && cp <= 0xDFFF || cp > utf8.MaxRune {
		return utf8.RuneError
	}
	return rune(cp)
}

func (z *tokenizer) consumeIdent() token {
	name := z.consumeName()
	if z.peek(0) != '(' {
		return z.token(tokIdent, name)
	}
	z.consume()
	if !equalASCIIFold(name, "url") {
		return z.token(tokFunction, name)
	}
	for isWhitespace(z.peek(0)) && (isWhitespace(z.peek(1)) || z.peek(1) == eof) {
		z.consume()
	}
	if p0, p1 := z.peek(0), z.peek(1); isQuote(p0) || isWhitespace(p0) && isQuote(p1) {
		return z.token(tokFunction, name)
	}
	return z.consumeURL()
}

func (z *tokenizer) consumeName() string {
	var b strings.Builder
	for z.pos < len(z.s) {
		if start := z.pos; z.scanWhile(isName) > 0 {
			b.WriteString(string(z.s[start:z.pos]))
			continue
		}
		z.consume()
		if !validEscape(z.current(), z.peek(0)) {
			z.reconsume()
			break
		}
		b.WriteRune(z.consumeEscaped())
	}
	return b.String()
}

func (z *tokenizer) consumeNumeric() token {
	if c := z.peek(0); c == '+' || c == '-' {
		z.consume()
	}
	z.digits()
	if z.peek(0) == '.' && isDigit(z.peek(1)) {
		z.consume()
		z.digits()
	}
	if e, p1, p2 := z.peek(0), z.peek(1), z.peek(2); (e == 'e' || e == 'E') && (isDigit(p1) || (p1 == '+' || p1 == '-') && isDigit(p2)) {
		z.consume()
		if !isDigit(p1) {
			z.consume()
		}
		// convert_string_to_number computes 10**exponent exactly.
		start := z.digits()
		exp := 0
		for _, d := range z.s[start:z.pos] {
			if exp = exp*10 + int(d-'0'); exp > maxExponent {
				z.err = ErrUnported
				break
			}
		}
	}
	if startIdentifier(z.peek(0), z.peek(1), z.peek(2)) {
		unit := z.consumeName()
		return z.token(tokDimension, unit)
	}
	if z.peek(0) == '%' {
		z.consume()
		return z.token(tokPercentage, "")
	}
	return z.token(tokNumber, "")
}

// digits consumes a run of digits and returns where it started.
func (z *tokenizer) digits() int {
	start := z.pos
	if z.scanWhile(isDigit) > maxNumberDigits {
		z.err = ErrUnported
	}
	return start
}

func (z *tokenizer) consumeString(ending rune) token {
	for z.pos < len(z.s) {
		switch z.consume() {
		case ending:
			return z.token(tokString, "")
		case '\n':
			z.reconsume()
			return z.token(tokBadString, "")
		case '\\':
			switch z.peek(0) {
			case eof:
			case '\n':
				z.consume()
			default:
				z.consumeEscaped()
			}
		}
	}
	return z.token(tokString, "")
}

// consumeUnicodeRange runs after "u+" has been consumed.
func (z *tokenizer) consumeUnicodeRange() token {
	n := 0
	for n < 6 && isHex(z.peek(0)) {
		z.consume()
		n++
	}
	wildcard := false
	for n < 6 && z.peek(0) == '?' {
		z.consume()
		n++
		wildcard = true
	}
	if !wildcard && z.peek(0) == '-' && isHex(z.peek(1)) {
		z.consume()
		for n := 0; n < 6 && isHex(z.peek(0)); n++ {
			z.consume()
		}
	}
	return z.token(tokUnicodeRange, "")
}

// consumeURL runs after an unquoted "url(" has been consumed.
func (z *tokenizer) consumeURL() token {
	z.scanWhile(isWhitespace)
	for z.pos < len(z.s) {
		switch c := z.consume(); {
		case c == ')':
			return z.token(tokURL, "")
		case isWhitespace(c):
			z.scanWhile(isWhitespace)
			if z.pos == len(z.s) || z.peek(0) == ')' {
				z.consume()
				return z.token(tokURL, "")
			}
			z.consumeBadURL()
			return z.token(tokBadURL, "")
		case isQuote(c) || c == '(' || isNonPrintable(c):
			z.consumeBadURL()
			return z.token(tokBadURL, "")
		case c == '\\':
			if !validEscape(z.current(), z.peek(0)) {
				z.consumeBadURL()
				return z.token(tokBadURL, "")
			}
			z.consumeEscaped()
		}
	}
	return z.token(tokURL, "")
}

func (z *tokenizer) consumeBadURL() {
	for z.pos < len(z.s) {
		switch {
		// Reads current, so a "\\" an escape just produced escapes the next character too.
		case validEscape(z.current(), z.peek(0)):
			z.consumeEscaped()
		case validEscape(z.peek(0), z.peek(1)):
			z.consume()
			z.consumeEscaped()
		default:
			if z.consume() == ')' {
				return
			}
		}
	}
}

func startIdentifier(c0, c1, c2 rune) bool {
	switch {
	case c0 == '-':
		return c1 == '-' || isNameStart(c1) || validEscape(c1, c2)
	case isNameStart(c0):
		return true
	}
	return validEscape(c0, c1)
}

func startNumber(c0, c1, c2 rune) bool {
	switch c0 {
	case '+', '-':
		return isDigit(c1) || c1 == '.' && isDigit(c2)
	case '.':
		return isDigit(c1)
	}
	return isDigit(c0)
}

func validEscape(c0, c1 rune) bool { return c0 == '\\' && c1 != '\n' }

func isWhitespace(c rune) bool { return c == '\n' || c == '\t' || c == ' ' }
func isQuote(c rune) bool      { return c == '"' || c == '\'' }
func isDigit(c rune) bool      { return c >= '0' && c <= '9' }
func isHex(c rune) bool        { return isDigit(c) || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F' }

func isNameStart(c rune) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_' || c >= 0x80
}

func isName(c rune) bool { return isNameStart(c) || isDigit(c) || c == '-' }

func isNonPrintable(c rune) bool {
	return c >= 0 && c <= 0x08 || c == 0x0B || c >= 0x0E && c <= 0x1F || c == 0x7F
}

func hexValue(c rune) int {
	switch {
	case c >= 'a':
		return int(c-'a') + 10
	case c >= 'A':
		return int(c-'A') + 10
	}
	return int(c - '0')
}

type nodeKind uint8

const (
	nodeToken nodeKind = iota
	nodeFunction
	nodeBlock
)

// node is a component value: a token, a function with the flat tokens it spans (which is
// what stringify prints), or a simple block with its contents (stringify closes it even
// when the input did not).
type node struct {
	kind     nodeKind
	tok      *token
	lo, hi   int
	children []*node
}

func (n *node) is(k kind) bool { return n.kind == nodeToken && n.tok.kind == k }

type itemKind uint8

const (
	itemToken itemKind = iota // whitespace or semicolon
	itemAtRule
	itemError
	itemProperty
)

// item is one entry of Parser#parse_properties' result.
type item struct {
	kind      itemKind
	tok       *token
	name      string
	children  []*node // the value, minus any trailing !important
	important bool
	decl      []*node // everything the declaration spans
}

type parser struct {
	toks []token
	pos  int
}

func parseProperties(input string) (*parser, []item, error) {
	toks, err := tokenize(input)
	if err != nil {
		return nil, nil, err
	}
	if nesting(toks) > maxNesting {
		return nil, nil, ErrUnported
	}
	p := &parser{toks: toks}
	return p, p.declarations(), nil
}

// nesting is the parser's recursion depth: a block ends only at its own closer.
func nesting(toks []token) int {
	var open []kind
	deepest := 0
	for _, t := range toks {
		switch t.kind {
		case tokFunction:
			open = append(open, tokCloseParen)
		case tokOpenParen, tokOpenSquare, tokOpenCurly:
			open = append(open, blocks[t.kind].closer)
		default:
			if n := len(open); n > 0 && open[n-1] == t.kind {
				open = open[:n-1]
			}
		}
		deepest = max(deepest, len(open))
	}
	return deepest
}

func (p *parser) consume() *token {
	if p.pos < len(p.toks) {
		p.pos++
		return &p.toks[p.pos-1]
	}
	return nil
}

func (p *parser) atSemicolonOrEnd() bool {
	return p.pos == len(p.toks) || p.toks[p.pos].kind == tokSemicolon
}

func (p *parser) declarations() []item {
	var items []item
	for t := p.consume(); t != nil; t = p.consume() {
		switch t.kind {
		case tokWhitespace, tokSemicolon:
			items = append(items, item{kind: itemToken, tok: t})
		case tokAtKeyword:
			p.atRule()
			items = append(items, item{kind: itemAtRule})
		case tokIdent:
			decl := []*node{{kind: nodeToken, tok: t}}
			for !p.atSemicolonOrEnd() {
				decl = append(decl, p.componentValue())
			}
			items = append(items, declaration(decl))
		default:
			items = append(items, item{kind: itemError})
			p.pos--
			for !p.atSemicolonOrEnd() {
				p.componentValue()
			}
		}
	}
	return items
}

// atRule runs after the at-keyword has been consumed.
func (p *parser) atRule() {
	for t := p.consume(); t != nil && t.kind != tokSemicolon; t = p.consume() {
		if t.kind == tokOpenCurly {
			p.block(t)
			return
		}
		p.pos--
		p.componentValue()
	}
}

func (p *parser) componentValue() *node {
	t := p.consume()
	switch t.kind {
	case tokOpenParen, tokOpenSquare, tokOpenCurly:
		return p.block(t)
	case tokFunction:
		return p.function(t)
	}
	return &node{kind: nodeToken, tok: t}
}

func (p *parser) block(open *token) *node {
	n := &node{kind: nodeBlock, tok: open}
	closer := blocks[open.kind].closer
	for t := p.consume(); t != nil && t.kind != closer; t = p.consume() {
		p.pos--
		n.children = append(n.children, p.componentValue())
	}
	return n
}

func (p *parser) function(fn *token) *node {
	n := &node{kind: nodeFunction, tok: fn, lo: p.pos - 1}
	for t := p.consume(); t != nil && t.kind != tokCloseParen; t = p.consume() {
		p.pos--
		p.componentValue()
	}
	n.hi = p.pos
	return n
}

// declaration is Parser#consume_declaration over an ident and the component values that
// followed it up to a semicolon.
func declaration(decl []*node) item {
	i := 1
	for i < len(decl) && decl[i].is(tokWhitespace) {
		i++
	}
	if i == len(decl) || !decl[i].is(tokColon) {
		return item{kind: itemError}
	}
	it := item{kind: itemProperty, name: decl[0].tok.value, children: decl[i+1:], decl: decl}

	var last []int
	for j := len(it.children) - 1; j >= 0 && len(last) < 2; j-- {
		if !it.children[j].is(tokWhitespace) {
			last = append(last, j)
		}
	}
	if len(last) == 2 {
		bang, word := it.children[last[1]], it.children[last[0]]
		if bang.is(tokDelim) && bang.tok.value == "!" && word.is(tokIdent) && equalASCIIFold(word.tok.value, "important") {
			it.important = true
			it.children = it.children[:last[1]]
		}
	}
	return it
}

var blocks = map[kind]struct {
	closer     kind
	start, end string
}{
	tokOpenParen:  {tokCloseParen, "(", ")"},
	tokOpenSquare: {tokCloseSquare, "[", "]"},
	tokOpenCurly:  {tokCloseCurly, "{", "}"},
}

func (p *parser) stringify(b *strings.Builder, n *node) {
	switch n.kind {
	case nodeToken:
		b.WriteString(n.tok.raw)
	case nodeFunction:
		for _, t := range p.toks[n.lo:n.hi] {
			b.WriteString(t.raw)
		}
	case nodeBlock:
		b.WriteString(blocks[n.tok.kind].start)
		for _, c := range n.children {
			p.stringify(b, c)
		}
		b.WriteString(blocks[n.tok.kind].end)
	}
}
