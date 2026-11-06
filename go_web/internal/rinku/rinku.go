// Package rinku is Rinku.auto_link(text, :all, link_attr) from rinku 2.0.6, byte for byte:
// the C extension (rinku.c, autolink.c, utf8.c) with its default skip tags, no block and no
// flags.
package rinku

import (
	"slices"
	"strings"
	"unicode/utf8"
)

const (
	actionWWW = iota + 1
	actionEmail
	actionURL
	actionSkipTag
)

var hrefPrefixes = [...]string{
	actionWWW:   `<a href="http://`,
	actionEmail: `<a href="mailto:`,
	actionURL:   `<a href="`,
}

var skipTags = []string{"a", "pre", "code", "kbd", "script"}

// AutoLink is Rinku.auto_link(text, :all, linkAttr). ok is false where Ruby raises
// ArgumentError instead: text that is not valid UTF-8.
func AutoLink(text, linkAttr string) (string, bool) {
	if !utf8.ValidString(text) {
		return "", false
	}
	return autoLink(text, linkAttr), true
}

// autoLink is rinku_autolink.
func autoLink(text, linkAttr string) string {
	size := len(text)
	if size == 0 {
		return text
	}
	// The attribute reaches C as a NUL-terminated string.
	if n := strings.IndexByte(linkAttr, 0); n >= 0 {
		linkAttr = linkAttr[:n]
	}
	for linkAttr != "" && isSpace(linkAttr[0]) {
		linkAttr = linkAttr[1:]
	}

	var b strings.Builder
	l := linker{data: text, emailFrom: -1, lt: -1}
	links := 0
	i, end := 0, 0
	for i < size {
		action := 0
		for end < size {
			if action = activeAction(text[end]); action != 0 {
				break
			}
			end++
		}
		if end == size {
			if links > 0 {
				b.WriteString(text[i:end])
			}
			break
		}
		if action == actionSkipTag {
			end += skipTag(text[end:])
			continue
		}

		var start, stop int
		var found bool
		switch action {
		case actionWWW:
			start, stop, found = l.matchWWW(end)
		case actionEmail:
			start, stop, found = l.matchEmail(end, i)
		case actionURL:
			start, stop, found = l.matchURL(end, i)
		}
		if !found {
			end++
			continue
		}
		if links == 0 {
			b.Grow(size + 128)
		}
		link := text[start:stop]
		b.WriteString(text[i:start])
		b.WriteString(hrefPrefixes[action])
		b.WriteString(strings.ReplaceAll(link, `"`, "&quot;"))
		b.WriteString(`" `)
		b.WriteString(linkAttr)
		b.WriteByte('>')
		b.WriteString(link)
		b.WriteString("</a>")
		links++
		end, i = stop, stop
	}
	// Ruby hands back the input itself when nothing was linked.
	if links == 0 {
		return text
	}
	return b.String()
}

func activeAction(c byte) int {
	switch c {
	case '<':
		return actionSkipTag
	case '@':
		return actionEmail
	case 'w', 'W':
		return actionWWW
	case ':':
		return actionURL
	}
	return 0
}

// skipTag is autolink__skip_tag on text starting at '<': it returns the offset of the '>'
// closing this tag or, for a skip tag, the first matching close tag; nesting is not counted.
func skipTag(text string) int {
	size := len(text)
	i := indexByteFrom(text, 0, '>')
	tag := ""
	for _, t := range skipTags {
		if htmlIsTag(text, t) == tagOpen {
			tag = t
			break
		}
	}
	if tag == "" {
		return i
	}
	for {
		i = indexByteFrom(text, i, '<')
		if i == size || htmlIsTag(text[i:], tag) == tagClose {
			break
		}
		i++
	}
	return indexByteFrom(text, i, '>')
}

func indexByteFrom(s string, from int, c byte) int {
	if n := strings.IndexByte(s[from:], c); n >= 0 {
		return from + n
	}
	return len(s)
}

const (
	tagNone = iota
	tagOpen
	tagClose
)

// htmlIsTag is sundown's html_is_tag: the name match is case-sensitive, so <A> and </A> are
// ordinary tags, and only whitespace or '>' may follow it (<a/> is not an <a>).
func htmlIsTag(data, name string) int {
	size := len(data)
	if size < 3 || data[0] != '<' {
		return tagNone
	}
	i := 1
	closed := data[i] == '/'
	if closed {
		i++
	}
	for j := 0; i < size && j < len(name); i, j = i+1, j+1 {
		if data[i] != name[j] {
			return tagNone
		}
	}
	if i == size || !isSpace(data[i]) && data[i] != '>' {
		return tagNone
	}
	if closed {
		return tagClose
	}
	return tagOpen
}

// linker carries one autoLink call's scan caches. Every check is a pure function of the input
// and a position, so the caches change no result; they keep seller-controlled text from
// making each trigger in a long run rescan the whole run.
type linker struct {
	data string

	// autolink__email's forward scan from emailFrom stopped at emailEnd, past emailAts '@'s
	// and emailDots counted dots. emailFrom < 0 when unset.
	emailFrom, emailEnd, emailAts, emailDots int

	host    hostRun
	hostSet bool

	// No '<' lies in [ltFrom, lt); lt is a '<' or len(data), and < 0 when unset.
	ltFrom, lt int
}

// matchWWW is autolink__www; data[pos] is 'w' or 'W'.
func (l *linker) matchWWW(pos int) (int, int, bool) {
	data := l.data
	if len(data)-pos < 4 || data[pos+1]|0x20 != 'w' || data[pos+2]|0x20 != 'w' || data[pos+3] != '.' {
		return 0, 0, false
	}
	if b := rewind(data, pos); b != 0 && !isSpaceRune(b) && !isPunctRune(b) {
		return 0, 0, false
	}
	end, ok := l.checkDomain(pos)
	if !ok {
		return 0, 0, false
	}
	return delimIter(data, pos, l.findSpace(end))
}

// matchEmail is autolink__email; data[pos] is '@'. rinku_autolink drops a match starting
// before minStart (inside the previous link), so that is refused before the forward scan.
func (l *linker) matchEmail(pos, minStart int) (int, int, bool) {
	data := l.data
	start := pos
	for ; start > 0; start-- {
		if c := data[start-1]; !isAlnum(c) && !inCSet(".+-_%", c) {
			break
		}
	}
	if start == pos || start < minStart {
		return 0, 0, false
	}
	end, nb, np := l.emailRun(pos)
	if end-pos < 2 || nb != 1 || np == 0 || np == 1 && data[end-1] == '.' {
		return 0, 0, false
	}
	end, ok := delim(data, start, end)
	return start, end, ok
}

// emailRun is autolink__email's forward scan over [alnum @ . - _] from pos: where it stops
// and how many '@' and '.' it passes. Every '@' in one run stops at the same byte, so a later
// one reuses the scan less what lies before it.
func (l *linker) emailRun(pos int) (end, ats, dots int) {
	data := l.data
	if l.emailFrom >= 0 && l.emailFrom <= pos && pos < l.emailEnd {
		for ; l.emailFrom < pos; l.emailFrom++ {
			switch data[l.emailFrom] {
			case '@':
				l.emailAts--
			case '.':
				l.emailDots--
			}
		}
		return l.emailEnd, l.emailAts, l.emailDots
	}
	size := len(data)
	end = pos
scan:
	for ; end < size; end++ {
		switch c := data[end]; {
		case isAlnum(c):
		case c == '@':
			ats++
		// A '.' ending the input is not part of the address.
		case c == '.' && end < size-1:
			dots++
		case c != '-' && c != '_':
			break scan
		}
	}
	l.emailFrom, l.emailEnd, l.emailAts, l.emailDots = pos, end, ats, dots
	return end, ats, dots
}

// matchURL is autolink__url; data[pos] is ':'. The scheme checks come before the host and
// space scans, which C runs first, so a ':' that cannot link stays cheap. As in matchEmail, a
// match starting before minStart is refused.
func (l *linker) matchURL(pos, minStart int) (int, int, bool) {
	data := l.data
	if len(data)-pos < 4 || data[pos+1] != '/' || data[pos+2] != '/' {
		return 0, 0, false
	}
	start := pos
	for start > 0 && isAlpha(data[start-1]) {
		start--
	}
	if start < minStart || !isSafe(data[start:]) {
		return 0, 0, false
	}
	end, ok := l.checkDomain(pos + 3)
	if !ok {
		return 0, 0, false
	}
	return delimIter(data, start, l.findSpace(end))
}

var safePrefixes = []string{"/", "http://", "https://", "ftp://", "mailto:"}

// isSafe is autolink_issafe.
func isSafe(link string) bool {
	for _, p := range safePrefixes {
		if len(link) > len(p) && asciiEqualFold(link[:len(p)], p) && isAlnum(link[len(p)]) {
			return true
		}
	}
	return false
}

func asciiEqualFold(a, b string) bool {
	for i := range len(a) {
		if lower(a[i]) != lower(b[i]) {
			return false
		}
	}
	return true
}

func lower(c byte) byte {
	if 'A' <= c && c <= 'Z' {
		return c + 'a' - 'A'
	}
	return c
}

// checkDomain is check_domain without AUTOLINK_SHORT_DOMAINS: the host needs a dot and no
// '_' in its last two labels. It returns where the host ends, which only seeds findSpace.
func (l *linker) checkDomain(start int) (int, bool) {
	data := l.data
	if !isAlnum(data[start]) {
		return 0, false
	}
	from, h := start+1, &l.host
	if !l.hostSet || from < h.from || from > h.end {
		*h = scanHost(data, from)
		l.hostSet = true
	}
	switch {
	case h.lastDot < from:
		return 0, false
	case h.prevDot >= from:
		return h.end, h.uscore1 == 0 && h.uscore2 == 0
	}
	// Only lastDot follows start, so the label before it begins at from.
	if h.uscore2 > 0 || strings.IndexByte(data[from:h.lastDot], '_') >= 0 {
		return 0, false
	}
	return h.end, true
}

// hostRun is one pass of check_domain's loop: no byte in [from, end) stops it, so a scan
// starting later in the run stops at end too, and only the dots after its start count.
type hostRun struct {
	from, end        int
	lastDot, prevDot int // -1 when absent
	uscore1, uscore2 int // '_' in the label ending at lastDot and in the one after it
}

// scanHost is check_domain's loop. Like the C, it never reads the last byte and steps
// bytewise, so continuation bytes pass as U+FFFD.
func scanHost(data string, from int) hostRun {
	h := hostRun{from: from, lastDot: -1, prevDot: -1}
	i := from
scan:
	for ; i < len(data)-1; i++ {
		switch c := data[i]; {
		case c == '_':
			h.uscore2++
		case c == '.':
			h.uscore1, h.uscore2 = h.uscore2, 0
			h.prevDot, h.lastDot = h.lastDot, i
		case c != '-' && !isValidHostChar(data, i):
			break scan
		}
	}
	h.end = i
	return h
}

func isValidHostChar(data string, i int) bool {
	c := next(data, &i)
	return !isSpaceRune(c) && !isPunctRune(c)
}

func delimIter(data string, start, end int) (int, int, bool) {
	for iterations := 0; end != 0; iterations++ {
		prev := end
		var ok bool
		if end, ok = delim(data, start, end); !ok {
			return 0, 0, false
		}
		if prev == end || iterations > 5 {
			break
		}
	}
	return start, end, true
}

// delim is autolink_delim: cut at '<', strip trailing punctuation and entities, then drop
// one unbalanced closing bracket or quote.
func delim(data string, start, end int) (int, bool) {
	if n := strings.IndexByte(data[start:end], '<'); n >= 0 {
		end = start + n
	}
	for end > start {
		c := data[end-1]
		if inCSet("?!.,:", c) {
			end--
			continue
		}
		if c != ';' {
			break
		}
		newEnd := end - 2
		for newEnd > 0 && isAlnum(data[newEnd]) {
			newEnd--
		}
		if newEnd < end-2 {
			if newEnd > 0 && data[newEnd] == '#' {
				newEnd--
			}
			if data[newEnd] == '&' {
				end = newEnd
				continue
			}
		}
		end--
	}
	if end == start {
		return end, false
	}

	cclose := rewind(data, end)
	copen := openParen(cclose)
	if copen == 0 {
		return end, true
	}
	opening, closing := 0, 0
	for i := start; i < end; {
		switch next(data, &i) {
		case copen:
			opening++
		case cclose:
			closing++
		}
	}
	// A quote is its own opener, so a trailing quote always counts as opening and goes.
	if copen == cclose && opening > 0 || copen != cclose && closing > opening {
		back(data, &end)
	}
	return end, true
}

// inCSet is strchr(set, c) != NULL, which also matches NUL (the terminator).
func inCSet(set string, c byte) bool {
	return c == 0 || strings.IndexByte(set, c) >= 0
}

func openParen(cclose int32) int32 {
	switch cclose {
	case '"', '\'':
		return cclose
	case ')':
		return '('
	case ']':
		return '['
	case '}':
		return '{'
	case 0xFF09, 0x3011, 0x300F, 0x300D, 0x300B, 0x3009: // ）】』」》〉
		return cclose - 1
	}
	return 0
}

// The utf8proc_* helpers decode without validating: read mid-character, a continuation byte
// comes back as U+FFFD with length 0.

func utf8Class(c byte) int {
	switch {
	case c < 0x80:
		return 1
	case c < 0xC0:
		return 0
	case c < 0xE0:
		return 2
	case c < 0xF0:
		return 3
	case c < 0xF8:
		return 4
	}
	return 0
}

func readCP(s string, length int) int32 {
	switch length {
	case 1:
		return int32(s[0])
	case 2:
		return int32(s[0]&0x1F)<<6 | int32(s[1]&0x3F)
	case 3:
		return int32(s[0]&0x0F)<<12 | int32(s[1]&0x3F)<<6 | int32(s[2]&0x3F)
	case 4:
		return int32(s[0]&0x07)<<18 | int32(s[1]&0x3F)<<12 | int32(s[2]&0x3F)<<6 | int32(s[3]&0x3F)
	}
	return 0xFFFD
}

func next(s string, pos *int) int32 {
	p := *pos
	length := utf8Class(s[p])
	*pos += length
	return readCP(s[p:], length)
}

// lastCharLen is the lead-byte search shared by utf8proc_rewind and utf8proc_back.
func lastCharLen(s string, pos int) int {
	switch {
	case s[pos-1] < 0x80:
		return 1
	case pos > 1 && utf8Class(s[pos-2]) == 2:
		return 2
	case pos > 2 && utf8Class(s[pos-3]) == 3:
		return 3
	case pos > 3 && utf8Class(s[pos-4]) == 4:
		return 4
	}
	return 0
}

func rewind(s string, pos int) int32 {
	if pos == 0 {
		return 0
	}
	length := lastCharLen(s, pos)
	return readCP(s[pos-length:], length)
}

func back(s string, pos *int) {
	if *pos > 0 {
		*pos -= lastCharLen(s, *pos)
	}
}

// findSpace is utf8proc_find_space stopped at the next '<', where delim cuts the link anyway:
// no '<' can sit between the link's start and the host's end. A U+FFFD, decoded or a
// continuation byte read mid-character, runs the link to that cut.
func (l *linker) findSpace(pos int) int {
	if l.lt < 0 || pos < l.ltFrom || pos > l.lt {
		l.ltFrom, l.lt = pos, indexByteFrom(l.data, pos, '<')
	}
	bound := l.lt
	for pos < bound {
		last := pos
		switch c := next(l.data, &pos); {
		case c == 0xFFFD:
			return bound
		case isSpaceRune(c):
			return last
		}
	}
	return bound
}

// ASCII classes from utf8.c's ctype_class: \v is a space here but not in isSpaceRune.
func isSpace(c byte) bool { return c == ' ' || '\t' <= c && c <= '\r' }
func isAlpha(c byte) bool { return 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' }
func isDigit(c byte) bool { return '0' <= c && c <= '9' }
func isAlnum(c byte) bool { return isAlpha(c) || isDigit(c) }
func isPunct(c byte) bool { return '!' <= c && c <= '~' && !isAlnum(c) }

func isSpaceRune(c int32) bool {
	switch c {
	case '\t', '\n', '\f', '\r', ' ', 0xA0, 0x1680, 0x202F, 0x205F, 0x3000:
		return true
	}
	return 0x2000 <= c && c <= 0x200A
}

func isPunctRune(c int32) bool {
	if c < 0x80 {
		return isPunct(byte(c))
	}
	_, found := slices.BinarySearchFunc(punctRanges, c, func(r [2]int32, c int32) int {
		switch {
		case r[1] < c:
			return -1
		case r[0] > c:
			return 1
		}
		return 0
	})
	return found
}

// punctRanges is utf8proc_is_punctuation above ASCII, as inclusive ranges.
var punctRanges = [][2]int32{
	{161, 161}, {167, 167}, {171, 171}, {182, 182},
	{183, 183}, {187, 187}, {191, 191}, {894, 894},
	{903, 903}, {1370, 1375}, {1417, 1417}, {1418, 1418},
	{1470, 1470}, {1472, 1472}, {1475, 1475}, {1478, 1478},
	{1523, 1523}, {1524, 1524}, {1545, 1545}, {1546, 1546},
	{1548, 1548}, {1549, 1549}, {1563, 1563}, {1566, 1566},
	{1567, 1567}, {1642, 1645}, {1748, 1748}, {1792, 1805},
	{2039, 2041}, {2096, 2110}, {2142, 2142}, {2404, 2404},
	{2405, 2405}, {2416, 2416}, {2800, 2800}, {3572, 3572},
	{3663, 3663}, {3674, 3674}, {3675, 3675}, {3844, 3858},
	{3860, 3860}, {3898, 3901}, {3973, 3973}, {4048, 4052},
	{4057, 4057}, {4058, 4058}, {4170, 4175}, {4347, 4347},
	{4960, 4968}, {5120, 5120}, {5741, 5741}, {5742, 5742},
	{5787, 5787}, {5788, 5788}, {5867, 5869}, {5941, 5941},
	{5942, 5942}, {6100, 6102}, {6104, 6106}, {6144, 6154},
	{6468, 6468}, {6469, 6469}, {6686, 6686}, {6687, 6687},
	{6816, 6822}, {6824, 6829}, {7002, 7008}, {7164, 7167},
	{7227, 7231}, {7294, 7294}, {7295, 7295}, {7360, 7367},
	{7379, 7379}, {8208, 8231}, {8240, 8259}, {8261, 8273},
	{8275, 8286}, {8317, 8317}, {8318, 8318}, {8333, 8333},
	{8334, 8334}, {8968, 8971}, {9001, 9001}, {9002, 9002},
	{10088, 10101}, {10181, 10181}, {10182, 10182}, {10214, 10223},
	{10627, 10648}, {10712, 10715}, {10748, 10748}, {10749, 10749},
	{11513, 11516}, {11518, 11518}, {11519, 11519}, {11632, 11632},
	{11776, 11822}, {11824, 11842}, {12289, 12291}, {12296, 12305},
	{12308, 12319}, {12336, 12336}, {12349, 12349}, {12448, 12448},
	{12539, 12539}, {42238, 42238}, {42239, 42239}, {42509, 42511},
	{42611, 42611}, {42622, 42622}, {42738, 42743}, {43124, 43127},
	{43214, 43214}, {43215, 43215}, {43256, 43258}, {43310, 43310},
	{43311, 43311}, {43359, 43359}, {43457, 43469}, {43486, 43486},
	{43487, 43487}, {43612, 43615}, {43742, 43742}, {43743, 43743},
	{43760, 43760}, {43761, 43761}, {44011, 44011}, {64830, 64830},
	{64831, 64831}, {65040, 65049}, {65072, 65106}, {65108, 65121},
	{65123, 65123}, {65128, 65128}, {65130, 65130}, {65131, 65131},
	{65281, 65283}, {65285, 65290}, {65292, 65295}, {65306, 65306},
	{65307, 65307}, {65311, 65311}, {65312, 65312}, {65339, 65341},
	{65343, 65343}, {65371, 65371}, {65373, 65373}, {65375, 65381},
	{65792, 65794}, {66463, 66463}, {66512, 66512}, {66927, 66927},
	{67671, 67671}, {67871, 67871}, {67903, 67903}, {68176, 68184},
	{68223, 68223}, {68336, 68342}, {68409, 68415}, {68505, 68508},
	{69703, 69709}, {69819, 69819}, {69820, 69820}, {69822, 69825},
	{69952, 69955}, {70004, 70004}, {70005, 70005}, {70085, 70088},
	{70093, 70093}, {70200, 70205}, {70854, 70854}, {71105, 71113},
	{71233, 71235}, {74864, 74868}, {92782, 92782}, {92783, 92783},
	{92917, 92917}, {92983, 92987}, {92996, 92996}, {113823, 113823},
}
