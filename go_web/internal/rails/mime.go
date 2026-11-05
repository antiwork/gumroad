package rails

import (
	"fmt"
	"math"
	"regexp"
	"sort"
	"strings"
)

// mimeTypes is Mime::LOOKUP, in registration order, for actionpack's mime_types.rb and
// config/initializers/mime_types.rb. A symbol's first entry is its canonical type.
var mimeTypes = []struct{ contentType, symbol string }{
	{"text/html", "html"}, {"application/xhtml+xml", "html"},
	{"text/plain", "text"},
	{"text/javascript", "js"}, {"application/javascript", "js"}, {"application/x-javascript", "js"},
	{"text/css", "css"}, {"text/calendar", "ics"}, {"text/csv", "csv"}, {"text/vcard", "vcf"}, {"text/vtt", "vtt"},
	{"text/markdown", "md"},
	{"image/png", "png"}, {"image/jpeg", "jpeg"}, {"image/gif", "gif"}, {"image/bmp", "bmp"}, {"image/tiff", "tiff"},
	{"image/svg+xml", "svg"}, {"image/webp", "webp"},
	{"video/mpeg", "mpeg"}, {"audio/mpeg", "mp3"}, {"audio/ogg", "ogg"}, {"audio/aac", "m4a"}, {"audio/mp4", "m4a"},
	{"video/webm", "webm"}, {"video/mp4", "mp4"},
	{"font/otf", "otf"}, {"font/ttf", "ttf"}, {"font/woff", "woff"}, {"font/woff2", "woff2"},
	{"application/xml", "xml"}, {"text/xml", "xml"}, {"application/x-xml", "xml"},
	{"application/rss+xml", "rss"}, {"application/atom+xml", "atom"},
	{"application/x-yaml", "yaml"}, {"text/yaml", "yaml"},
	{"multipart/form-data", "multipart_form"}, {"application/x-www-form-urlencoded", "url_encoded_form"},
	{"application/json", "json"}, {"text/x-json", "json"}, {"application/jsonrequest", "json"}, {"application/problem+json", "json"},
	{"application/pdf", "pdf"}, {"application/zip", "zip"}, {"application/gzip", "gzip"}, {"application/x-gzip", "gzip"},
	{"application/smil+xml", "smil"}, {"application/x-mpegurl", "m3u8"},
}

// mimeExtensions is Mime::EXTENSION_LOOKUP, which params[:format] goes through.
var mimeExtensions = map[string]string{
	"html": "html", "xhtml": "html", "text": "text", "txt": "text", "js": "js", "css": "css", "ics": "ics", "csv": "csv",
	"vcf": "vcf", "vtt": "vtt", "md": "md", "markdown": "md", "png": "png", "jpeg": "jpeg", "jpg": "jpeg", "jpe": "jpeg",
	"pjpeg": "jpeg", "gif": "gif", "bmp": "bmp", "tiff": "tiff", "tif": "tiff", "svg": "svg", "webp": "webp",
	"mpeg": "mpeg", "mpg": "mpeg", "mpe": "mpeg", "mp3": "mp3", "mp1": "mp3", "mp2": "mp3", "ogg": "ogg", "oga": "ogg",
	"spx": "ogg", "opus": "ogg", "m4a": "m4a", "mpg4": "m4a", "aac": "m4a", "webm": "webm", "mp4": "mp4", "m4v": "mp4",
	"otf": "otf", "ttf": "ttf", "woff": "woff", "woff2": "woff2", "xml": "xml", "rss": "rss", "atom": "atom",
	"yaml": "yaml", "yml": "yaml", "multipart_form": "multipart_form", "url_encoded_form": "url_encoded_form",
	"json": "json", "pdf": "pdf", "zip": "zip", "gzip": "gzip", "gz": "gzip", "smil": "smil", "m3u8": "m3u8",
}

// AnyFormat is Mime::ALL's ref.
const AnyFormat = "*/*"

var (
	symbolsByType  = map[string]string{}
	typesBySymbol  = map[string]string{}
	mimeNameSource = `[a-zA-Z0-9][a-zA-Z0-9!#$&\-^_.+]{0,126}`
	// Mime::Type::MIME_REGEXP, which Mime::Type.new enforces on unregistered types.
	mimeRegexp = regexp.MustCompile(`\A(?:\*/\*|` + mimeNameSource + `/(?:\*|` + mimeNameSource + `)(?:\s*;\s*` +
		mimeNameSource + `(?:=(?:` + mimeNameSource + `|"[^"\r\\]*"))?)*\s*)\z`)
	// AcceptItem's `;\s*q="?` and ACCEPT_HEADER_REGEXP.
	qSeparator  = regexp.MustCompile(`;\s*q="?`)
	acceptItems = regexp.MustCompile(`[^,\s"](?:[^,"]|"[^"]*")*`)
)

func init() {
	for _, m := range mimeTypes {
		symbolsByType[m.contentType] = m.symbol
		if _, ok := typesBySymbol[m.symbol]; !ok {
			typesBySymbol[m.symbol] = m.contentType
		}
	}
}

// lookupMime is Mime::Type.lookup: a registered symbol, "" for a valid unregistered type.
func lookupMime(s string) (string, error) {
	if symbol, ok := symbolsByType[s]; ok {
		return symbol, nil
	}
	s = strings.TrimSpace(strings.SplitN(strings.ToLower(s), ";", 2)[0])
	if s == AnyFormat {
		return AnyFormat, nil
	}
	if symbol, ok := symbolsByType[s]; ok {
		return symbol, nil
	}
	if !mimeRegexp.MatchString(s) {
		return "", ErrNotAcceptable
	}
	return "", nil
}

// parseAccept is Mime::Type.parse. It returns symbols; "" stands for a valid type Rails
// has not registered.
func parseAccept(header string) ([]string, error) {
	if !strings.Contains(header, ",") {
		if loc := qSeparator.FindStringIndex(header); loc != nil {
			header = strings.TrimSpace(header[:loc[0]])
		}
		if strings.TrimSpace(header) == "" {
			return nil, nil
		}
		if expanded := trailingStar(header); expanded != nil {
			return expanded, nil
		}
		symbol, err := lookupMime(header)
		if err != nil {
			return nil, err
		}
		return []string{symbol}, nil
	}

	type item struct {
		index int
		name  string
		// q is (q.to_f * 100).to_i, kept as a float: truncated floats order as the Integers
		// Ruby makes of them, Bignums included.
		q float64
	}
	var items []item
	for _, raw := range acceptItems.FindAllString(header, -1) {
		parts := qSeparator.Split(raw, 2)
		name := strings.TrimSpace(parts[0])
		if name == "" {
			continue
		}
		var q *float64
		if len(parts) == 2 {
			f, _ := StringToF(parts[1])
			q = &f
		}
		names := trailingStar(name)
		if names == nil {
			names = []string{name}
		} else {
			for i, symbol := range names {
				names[i] = typesBySymbol[symbol]
			}
		}
		for _, n := range names {
			weight := 1.0
			if q != nil {
				weight = *q
			} else if n == AnyFormat {
				weight = 0
			}
			scaled := weight * 100
			if math.IsInf(scaled, 0) {
				// Infinity#to_i raises FloatDomainError.
				return nil, errInfiniteQuality
			}
			items = append(items, item{index: len(items), name: n, q: math.Trunc(scaled)})
		}
	}
	sort.SliceStable(items, func(i, j int) bool { return items[i].q > items[j].q })

	var symbols []string
	seen := map[string]bool{}
	for _, it := range items {
		symbol, err := lookupMime(it.name)
		if err != nil {
			return nil, err
		}
		// Unregistered types are distinct Mime::Type objects, so uniq! keeps each one.
		key := symbol
		if symbol == "" {
			key = "unregistered:" + it.name
		}
		if !seen[key] {
			seen[key] = true
			symbols = append(symbols, symbol)
		}
	}
	return symbols, nil
}

// trailingStar is parse_trailing_star: text/* and application/* expand to every type
// registered under them.
// errInfiniteQuality raises while Rails parses formats, and again while ShowExceptions
// picks the error page's format, so Rails answers with its failsafe response.
var errInfiniteQuality = fmt.Errorf("an Accept quality Rails raises FloatDomainError on: %w", ErrFailsafe)

func trailingStar(name string) []string {
	prefix := ""
	switch {
	case strings.HasPrefix(name, "text/*"):
		prefix = "text/"
	case strings.HasPrefix(name, "application/*"):
		prefix = "application/"
	default:
		return nil
	}
	var out []string
	seen := map[string]bool{}
	for _, m := range mimeTypes {
		if strings.HasPrefix(m.contentType, prefix) && !seen[m.symbol] && typesBySymbol[m.symbol] == m.contentType {
			seen[m.symbol] = true
			out = append(out, m.symbol)
		}
	}
	return out
}

var browserLikeAccepts = regexp.MustCompile(`,\s*\*/\*|\*/\*\s*,`)

// formats is ActionDispatch::Http::MimeNegotiation#formats, as symbols. fromAccept is
// should_apply_vary_header?.
func formats(formatParam any, accept, contentType string, xhr bool, path string) (out []string, fromAccept bool, err error) {
	hasAccept := strings.TrimSpace(accept) != ""
	switch {
	case Truthy(formatParam):
		if symbol, ok := mimeExtensions[ToS(formatParam)]; ok {
			return []string{symbol}, false, nil
		}
		return nil, false, nil
	case (xhr && (hasAccept || contentType != "")) || (hasAccept && !browserLikeAccepts.MatchString(accept)):
		var accepts []string
		if hasAccept {
			accepts, err = parseAccept(strings.TrimSpace(accept))
		} else {
			var symbol string
			symbol, err = lookupMime(contentType)
			accepts = []string{symbol}
		}
		if err != nil {
			return nil, false, err
		}
		for _, symbol := range accepts {
			if symbol != "" {
				out = append(out, symbol)
			}
		}
		return out, true, nil
	}
	if i := strings.LastIndexByte(path, '.'); i >= 0 && isWord(path[i+1:]) {
		if symbol, ok := mimeExtensions[path[i+1:]]; ok {
			return []string{symbol}, false, nil
		}
		return nil, false, nil
	}
	if xhr {
		return []string{"js"}, false, nil
	}
	return []string{"html"}, false, nil
}

// ContentTypeFor is Mime[symbol]'s type, "" for an unregistered symbol.
func ContentTypeFor(symbol string) string { return typesBySymbol[symbol] }

// Negotiate is respond_to's negotiate_mime: the first requested format the action
// declares, "*/*" picking the first declared. "" means none matched.
func Negotiate(requested []string, declared ...string) string {
	for _, f := range requested {
		if f == AnyFormat {
			return declared[0]
		}
		for _, d := range declared {
			if f == d {
				return d
			}
		}
	}
	return ""
}

func isWord(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c == '_' || c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z') {
			return false
		}
	}
	return true
}
