package webhooks

import (
	"encoding/base64"
	"strconv"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// Helpers that reproduce the Ruby semantics these actions rely on and internal/rails
// doesn't cover.

// rubyInteger mirrors Kernel#Integer on a String: surrounding whitespace, one sign, a
// 0x/0b/0o/0d prefix or a leading 0 for octal, and single underscores between digits.
// Values outside int64 are refused; Ruby would make a Bignum.
func rubyInteger(s string) (int64, bool) {
	if strings.IndexByte(s, 0) >= 0 {
		return 0, false
	}
	s = strings.Trim(s, rails.RubySpace)
	sign := ""
	if s != "" && (s[0] == '+' || s[0] == '-') {
		sign, s = s[:1], s[1:]
	}
	base := 10
	if len(s) > 1 && s[0] == '0' {
		switch s[1] {
		case 'x', 'X':
			base, s = 16, s[2:]
		case 'b', 'B':
			base, s = 2, s[2:]
		case 'o', 'O':
			base, s = 8, s[2:]
		case 'd', 'D':
			base, s = 10, s[2:]
		default:
			base = 8
		}
	}
	if s == "" || s[0] == '_' || s[0] == '+' || s[0] == '-' || s[len(s)-1] == '_' || strings.Contains(s, "__") {
		return 0, false
	}
	n, err := strconv.ParseInt(sign+strings.ReplaceAll(s, "_", ""), base, 64)
	return n, err == nil
}

func isBase64Alphabet(c byte) bool {
	return c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '+' || c == '/'
}

// rubyDecode64 mirrors Base64.decode64 (pack.c's lenient "m"): characters outside the
// alphabet are skipped, a '=' in a group's third or fourth place ends the data, and a
// lone trailing character is dropped.
func rubyDecode64(s string) []byte {
	kept := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		switch c := s[i]; {
		case isBase64Alphabet(c):
			kept = append(kept, c)
		case c == '=' && len(kept)%4 >= 2:
			i = len(s)
		}
	}
	if len(kept)%4 == 1 {
		kept = kept[:len(kept)-1]
	}
	out := make([]byte, base64.RawStdEncoding.DecodedLen(len(kept)))
	n, _ := base64.RawStdEncoding.Decode(out, kept)
	return out[:n]
}
