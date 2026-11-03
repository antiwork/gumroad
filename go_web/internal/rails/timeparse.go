package rails

import (
	"errors"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// ErrUnsupportedTime means the input is outside the subset of Date._parse ported here:
// Go cannot vouch for what Rails would have read, so the caller should decline it.
var ErrUnsupportedTime = errors.New("time is not in a format go_web parses")

// TimeArgumentError is the ArgumentError (or Date::Error) Time.new, DateTime.new or
// Date._parse raises: a 500 in Rails.
type TimeArgumentError struct{ Message string }

func (e TimeArgumentError) Error() string { return e.Message }

// Date._parse refuses longer strings by default.
const maxTimeStringLength = 128

var (
	dateParseJunk = regexp.MustCompile(`[^-+',./:@\pL\pN\[\]]+`)
	parseDayRe    = regexp.MustCompile(`(?i)\b(sun|mon|tue|wed|thu|fri|sat)[^-/\d\s]*`)
	// parse_time's pattern; group 2 is the zone.
	parseTimeRe = regexp.MustCompile(`(?i)(\d+\s*(?:(?::\s*\d+(?:\s*:\s*\d+(?:[,.]\d*)?)?|h(?:\s*\d+m?(?:\s*\d+s?)?)?)(?:\s*[ap](?:m\b|\.m\.))?|[ap](?:m\b|\.m\.)))` +
		`(?:\s*((?:gmt|utc?)?[-+]\d+(?:[,.:]\d+(?::\d+)?)?|[\pL.\s]+(?:standard|daylight)\stime\b|\pL+(?:\sdst)?\b))?`)
	// parse_time_cb's pattern for the time part alone.
	timePartsRe = regexp.MustCompile(`(?i)\A(\d+)h?(?:\s*:?\s*(\d+)m?(?:\s*:?\s*(\d+)(?:[,.](\d+))?s?)?)?(?:\s*([ap])(?:m\b|\.m\.))?`)
	monthNames  = `(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)`
	parseEuRe   = regexp.MustCompile(`(?i)('?\d+)[^-\d\s]*\s*` + monthNames + `[^-\d\s']*(?:\s*('?-?\d+(?:(?:st|nd|rd|th)\b)?))?`)
	parseUsRe   = regexp.MustCompile(`(?i)\b` + monthNames + `[^-\d\s']*\s*('?\d+)[^-\d\s']*(?:\s*,?\s*('?-?\d+))?`)
	parseIsoRe  = regexp.MustCompile(`('?[-+]?\d+)-(\d+)-('?-?\d+)`)
	eraRe       = regexp.MustCompile(`(?i)\b(c(?:e|\.e\.)|b(?:ce|\.c\.e\.)|a(?:d|\.d\.)|b(?:c|\.c\.))`)
	basicIsoRe  = regexp.MustCompile(`\A(\d{4})(\d{2})(\d{2})[Tt](\d{2})(\d{2})(\d{2})(?:([zZ])|([-+]\d{4}))?\z`)
	digitsRe    = regexp.MustCompile(`\A\d+\z`)
	monthOrDay  = regexp.MustCompile(`(?i)(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec|sun|mon|tue|wed|thu|fri|sat)`)
)

type dateParts struct {
	year, mon, mday *int
	hour, min, sec  int
	nanos           int
	offset          *int
	hasTime         bool
}

// ZoneParse is ActiveSupport::TimeZone#parse with Time.zone = UTC: Date._parse(str, false)
// then Time.new, which rolls Feb 30 over to March. It returns nil where Rails does.
func ZoneParse(input string, now time.Time) (*time.Time, error) {
	parts, err := dateParse(input)
	if err != nil || parts == nil {
		return nil, err
	}
	return parts.toTime(now)
}

// DateTimeParse is String#to_datetime (DateTime.parse(str, false)): nil for a blank
// string, Date::Error for an empty parse or an invalid civil date, and DateTime's own
// rules for 24:00 and leap seconds. The offset is kept.
func DateTimeParse(input string, now time.Time) (*time.Time, error) {
	if Blank(input) {
		return nil, nil
	}
	parts, err := dateParse(input)
	if err != nil {
		return nil, err
	}
	if parts == nil {
		return nil, TimeArgumentError{"invalid date"}
	}
	return parts.toDateTime(now)
}

// dateParse is the subset of Date._parse(str, false) ported here; nil parts is its {}.
func dateParse(input string) (*dateParts, error) {
	if utf8.RuneCountInString(input) > maxTimeStringLength {
		return nil, TimeArgumentError{"string length exceeds the limit 128"}
	}
	s := dateParseJunk.ReplaceAllString(input, " ")
	if !strings.ContainsAny(s, "0123456789") {
		if monthOrDay.MatchString(s) {
			return nil, ErrUnsupportedTime
		}
		return nil, nil
	}
	if eraRe.MatchString(s) {
		return nil, ErrUnsupportedTime
	}

	var parts dateParts
	if m := basicIsoRe.FindStringSubmatch(strings.TrimSpace(s)); m != nil {
		parts.year, parts.mon, parts.mday = intPtr(atoi(m[1])), intPtr(atoi(m[2])), intPtr(atoi(m[3]))
		parts.hour, parts.min, parts.sec, parts.hasTime = atoi(m[4]), atoi(m[5]), atoi(m[6]), true
		switch {
		case m[7] != "":
			parts.offset = intPtr(0)
		case m[8] != "":
			parts.offset = zoneOffset(m[8])
		}
		return &parts, nil
	}

	s = firstOnly(parseDayRe, s)
	if loc := parseTimeRe.FindStringSubmatchIndex(s); loc != nil {
		timePart := s[loc[2]:loc[3]]
		if !strings.Contains(timePart, ":") {
			return nil, ErrUnsupportedTime
		}
		if loc[4] >= 0 {
			zone := s[loc[4]:loc[5]]
			if strings.HasSuffix(strings.ToLower(zone), "time") && strings.ContainsAny(zone, " \t") {
				return nil, ErrUnsupportedTime
			}
			if parts.offset = zoneOffset(zone); parts.offset == nil && zoneIsFractional(zone) {
				return nil, ErrUnsupportedTime
			}
		}
		if err := parts.setTime(timePart); err != nil {
			return nil, err
		}
		s = s[:loc[0]] + " " + s[loc[1]:]
	}

	var y, m, d string
	matched := false
	if loc := parseEuRe.FindStringSubmatchIndex(s); loc != nil {
		d, m = s[loc[2]:loc[3]], strconv.Itoa(monthNumber(s[loc[4]:loc[5]]))
		if loc[6] >= 0 {
			y = s[loc[6]:loc[7]]
		}
		s, matched = s[:loc[0]]+" "+s[loc[1]:], true
	} else if loc := parseUsRe.FindStringSubmatchIndex(s); loc != nil {
		m, d = strconv.Itoa(monthNumber(s[loc[2]:loc[3]])), s[loc[4]:loc[5]]
		if loc[6] >= 0 {
			y = s[loc[6]:loc[7]]
		}
		s, matched = s[:loc[0]]+" "+s[loc[1]:], true
	} else if loc := parseIsoRe.FindStringSubmatchIndex(s); loc != nil {
		y, m, d = s[loc[2]:loc[3]], s[loc[4]:loc[5]], s[loc[6]:loc[7]]
		s, matched = s[:loc[0]]+" "+s[loc[1]:], true
	}
	if matched {
		// s3e only keeps this order when month and day are at most two digits.
		if !digitsRe.MatchString(m) || len(m) > 2 || !digitsRe.MatchString(d) || len(d) > 2 || (y != "" && !digitsRe.MatchString(y)) {
			return nil, ErrUnsupportedTime
		}
		if y != "" {
			parts.year = intPtr(atoi(y))
		}
		parts.mon, parts.mday = intPtr(atoi(m)), intPtr(atoi(d))
	} else if !parts.hasTime {
		return nil, ErrUnsupportedTime
	}
	// Whatever is left must be separators the other sub-parsers and parse_frag ignore.
	if strings.Trim(s, " Tt,.") != "" {
		return nil, ErrUnsupportedTime
	}
	return &parts, nil
}

func firstOnly(re *regexp.Regexp, s string) string {
	if loc := re.FindStringIndex(s); loc != nil {
		return s[:loc[0]] + " " + s[loc[1]:]
	}
	return s
}

func (p *dateParts) setTime(timePart string) error {
	m := timePartsRe.FindStringSubmatch(timePart)
	if m == nil {
		return ErrUnsupportedTime
	}
	p.hasTime = true
	p.hour = atoi(m[1])
	if m[2] != "" {
		p.min = atoi(m[2])
	}
	if m[3] != "" {
		p.sec = atoi(m[3])
	}
	if m[4] != "" {
		frac := m[4]
		if len(frac) > 9 {
			frac = frac[:9]
		}
		p.nanos = atoi(frac + strings.Repeat("0", 9-len(frac)))
	}
	if m[5] != "" {
		p.hour %= 12
		if m[5] == "p" || m[5] == "P" {
			p.hour += 12
		}
	}
	return nil
}

// toTime is parts_to_time's Time.new(year, mon, mday, hour, min, sec + fraction, offset).
func (p *dateParts) toTime(now time.Time) (*time.Time, error) {
	now = now.UTC()
	year, mon, mday := now.Year(), int(now.Month()), now.Day()
	if p.year != nil {
		year = *p.year
	}
	if p.mon != nil {
		mon = *p.mon
	}
	switch {
	case p.mday != nil:
		mday = *p.mday
	case p.year != nil || p.mon != nil:
		mday = 1
	}
	switch {
	case mon < 1 || mon > 12:
		return nil, TimeArgumentError{"mon out of range"}
	case mday == 0:
		return nil, TimeArgumentError{"mday out of range"}
	case mday < 0 || mday > 31:
		return nil, TimeArgumentError{"argument out of range"}
	case p.hour > 24:
		return nil, TimeArgumentError{"hour out of range"}
	case p.min > 59 || (p.hour == 24 && p.min > 0):
		return nil, TimeArgumentError{"min out of range"}
	case p.sec > 60 || (p.hour == 24 && (p.sec > 0 || p.nanos > 0)):
		return nil, TimeArgumentError{"sec out of range"}
	}
	offset := 0
	if p.offset != nil {
		offset = *p.offset
	}
	if offset <= -86400 || offset >= 86400 {
		return nil, TimeArgumentError{"utc_offset out of range"}
	}
	t := time.Date(year, time.Month(mon), mday, p.hour, p.min, p.sec, p.nanos, time.FixedZone("", offset)).UTC()
	return &t, nil
}

// zoneOffset is date_zone_to_diff for the zones parse_time captures: a word from the zone
// table, optionally followed by " dst", or a numeric offset with an optional gmt/utc prefix.
// nil is Ruby's nil offset, which Time.zone.parse reads as UTC.
func zoneOffset(zone string) *int {
	lower := strings.ToLower(zone)
	dst := 0
	if strings.HasSuffix(lower, " dst") {
		lower, dst = strings.TrimSpace(strings.TrimSuffix(lower, " dst")), 3600
	}
	if offset, ok := zoneOffsets[strings.Join(strings.Fields(lower), " ")]; ok {
		return intPtr(offset + dst)
	}
	s := lower
	if len(s) > 3 && (strings.HasPrefix(s, "gmt") || strings.HasPrefix(s, "utc")) {
		s = s[3:]
	}
	if s == "" || (s[0] != '+' && s[0] != '-') {
		return nil
	}
	negative := s[0] == '-'
	s = s[1:]
	hourDigits := leadingDigits(s)
	var hour, min, sec int
	switch rest := s[len(hourDigits):]; {
	case strings.HasPrefix(rest, ":"):
		hour = atoi(hourDigits)
		if hour > 23 {
			return nil
		}
		minDigits := leadingDigits(rest[1:])
		if min = atoi(minDigits); min > 59 {
			return nil
		}
		if after := rest[1+len(minDigits):]; strings.HasPrefix(after, ":") {
			if sec = atoi(leadingDigits(after[1:])); sec > 59 {
				return nil
			}
		}
	case strings.HasPrefix(rest, ",") || strings.HasPrefix(rest, "."):
		return nil
	case len(s) > 2:
		width := 2 - len(s)%2
		hour = atoi(leadingDigits(s[:min2(width, len(s))]))
		if len(s) >= 3 {
			min = atoi(leadingDigits(s[width:min2(width+2, len(s))]))
		}
		if len(s) >= 5 {
			sec = atoi(leadingDigits(s[width+2 : min2(width+4, len(s))]))
		}
	default:
		hour = atoi(hourDigits)
	}
	total := hour*3600 + min*60 + sec
	if negative {
		total = -total
	}
	return &total
}

func zoneIsFractional(zone string) bool {
	return strings.ContainsAny(zone, ",.") && strings.ContainsAny(zone, "+-")
}

func monthNumber(name string) int {
	return strings.Index("janfebmaraprmayjunjulaugsepoctnovdec", strings.ToLower(name[:3]))/3 + 1
}

func leadingDigits(s string) string {
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i++
	}
	return s[:i]
}

func atoi(s string) int {
	n := 0
	for i := 0; i < len(s) && unicode.IsDigit(rune(s[i])); i++ {
		n = n*10 + int(s[i]-'0')
		if n > 1<<40 {
			return n
		}
	}
	return n
}

func min2(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func intPtr(n int) *int { return &n }

// toDateTime is DateTime.civil's validation: no rollover, 24:00:00 is the next midnight,
// and a leap second reads as :59.
func (p *dateParts) toDateTime(now time.Time) (*time.Time, error) {
	now = now.UTC()
	year, mon, mday := now.Year(), int(now.Month()), now.Day()
	if p.year != nil || p.mon != nil || p.mday != nil {
		if p.year == nil || p.mon == nil || p.mday == nil {
			return nil, ErrUnsupportedTime
		}
		year, mon, mday = *p.year, *p.mon, *p.mday
	}
	if mon < 1 || mon > 12 || mday < 1 || mday > time.Date(year, time.Month(mon)+1, 0, 0, 0, 0, 0, time.UTC).Day() {
		return nil, TimeArgumentError{"invalid date"}
	}
	sec := p.sec
	if sec == 60 {
		sec = 59
	}
	if p.hour > 24 || p.min > 59 || sec > 59 || (p.hour == 24 && (p.min > 0 || sec > 0 || p.nanos > 0)) {
		return nil, TimeArgumentError{"invalid date"}
	}
	offset := 0
	if p.offset != nil {
		offset = *p.offset
	}
	if offset < -86400 || offset > 86400 {
		return nil, ErrUnsupportedTime
	}
	t := time.Date(year, time.Month(mon), mday, p.hour, p.min, sec, p.nanos, time.FixedZone("", offset))
	return &t, nil
}
