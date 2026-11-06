package rails

import (
	"regexp"
	"strings"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"
)

var (
	nonSlug       = regexp.MustCompile(`(?i)[^a-z0-9\-_]+`)
	slugDashRun   = regexp.MustCompile(`-{2,}`)
	slugDashEdges = regexp.MustCompile(`^-|-$`)
)

// Parameterize is String#parameterize: transliterate, then dashes for anything else.
func Parameterize(s string) string {
	s = nonSlug.ReplaceAllString(transliterate(s), "-")
	s = slugDashRun.ReplaceAllString(s, "-")
	return strings.ToLower(slugDashEdges.ReplaceAllString(s, ""))
}

// transliterate is ActiveSupport's transliterate: NFC, then each non-ASCII character's
// approximation, else "?". x/text's tables are Unicode 15.0 below go1.27, as Ruby 3.4's are.
func transliterate(s string) string {
	if IsASCII(s) {
		return s
	}
	var b strings.Builder
	for _, r := range norm.NFC.String(s) {
		switch t, ok := transliterations[r]; {
		case r < utf8.RuneSelf:
			b.WriteRune(r)
		case ok:
			b.WriteString(t)
		default:
			b.WriteByte('?')
		}
	}
	return b.String()
}

// IsASCII is String#ascii_only?.
func IsASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= utf8.RuneSelf {
			return false
		}
	}
	return true
}

// transliterations is I18n's DEFAULT_APPROXIMATIONS, the only transliteration rules any of the
// app's locales has, as Rails loaded it.
var transliterations = map[rune]string{
	0x00C0: "A",  // À
	0x00C1: "A",  // Á
	0x00C2: "A",  // Â
	0x00C3: "A",  // Ã
	0x00C4: "A",  // Ä
	0x00C5: "A",  // Å
	0x00C6: "AE", // Æ
	0x00C7: "C",  // Ç
	0x00C8: "E",  // È
	0x00C9: "E",  // É
	0x00CA: "E",  // Ê
	0x00CB: "E",  // Ë
	0x00CC: "I",  // Ì
	0x00CD: "I",  // Í
	0x00CE: "I",  // Î
	0x00CF: "I",  // Ï
	0x00D0: "D",  // Ð
	0x00D1: "N",  // Ñ
	0x00D2: "O",  // Ò
	0x00D3: "O",  // Ó
	0x00D4: "O",  // Ô
	0x00D5: "O",  // Õ
	0x00D6: "O",  // Ö
	0x00D7: "x",  // ×
	0x00D8: "O",  // Ø
	0x00D9: "U",  // Ù
	0x00DA: "U",  // Ú
	0x00DB: "U",  // Û
	0x00DC: "U",  // Ü
	0x00DD: "Y",  // Ý
	0x00DE: "Th", // Þ
	0x00DF: "ss", // ß
	0x00E0: "a",  // à
	0x00E1: "a",  // á
	0x00E2: "a",  // â
	0x00E3: "a",  // ã
	0x00E4: "a",  // ä
	0x00E5: "a",  // å
	0x00E6: "ae", // æ
	0x00E7: "c",  // ç
	0x00E8: "e",  // è
	0x00E9: "e",  // é
	0x00EA: "e",  // ê
	0x00EB: "e",  // ë
	0x00EC: "i",  // ì
	0x00ED: "i",  // í
	0x00EE: "i",  // î
	0x00EF: "i",  // ï
	0x00F0: "d",  // ð
	0x00F1: "n",  // ñ
	0x00F2: "o",  // ò
	0x00F3: "o",  // ó
	0x00F4: "o",  // ô
	0x00F5: "o",  // õ
	0x00F6: "o",  // ö
	0x00F8: "o",  // ø
	0x00F9: "u",  // ù
	0x00FA: "u",  // ú
	0x00FB: "u",  // û
	0x00FC: "u",  // ü
	0x00FD: "y",  // ý
	0x00FE: "th", // þ
	0x00FF: "y",  // ÿ
	0x0100: "A",  // Ā
	0x0101: "a",  // ā
	0x0102: "A",  // Ă
	0x0103: "a",  // ă
	0x0104: "A",  // Ą
	0x0105: "a",  // ą
	0x0106: "C",  // Ć
	0x0107: "c",  // ć
	0x0108: "C",  // Ĉ
	0x0109: "c",  // ĉ
	0x010A: "C",  // Ċ
	0x010B: "c",  // ċ
	0x010C: "C",  // Č
	0x010D: "c",  // č
	0x010E: "D",  // Ď
	0x010F: "d",  // ď
	0x0110: "D",  // Đ
	0x0111: "d",  // đ
	0x0112: "E",  // Ē
	0x0113: "e",  // ē
	0x0114: "E",  // Ĕ
	0x0115: "e",  // ĕ
	0x0116: "E",  // Ė
	0x0117: "e",  // ė
	0x0118: "E",  // Ę
	0x0119: "e",  // ę
	0x011A: "E",  // Ě
	0x011B: "e",  // ě
	0x011C: "G",  // Ĝ
	0x011D: "g",  // ĝ
	0x011E: "G",  // Ğ
	0x011F: "g",  // ğ
	0x0120: "G",  // Ġ
	0x0121: "g",  // ġ
	0x0122: "G",  // Ģ
	0x0123: "g",  // ģ
	0x0124: "H",  // Ĥ
	0x0125: "h",  // ĥ
	0x0126: "H",  // Ħ
	0x0127: "h",  // ħ
	0x0128: "I",  // Ĩ
	0x0129: "i",  // ĩ
	0x012A: "I",  // Ī
	0x012B: "i",  // ī
	0x012C: "I",  // Ĭ
	0x012D: "i",  // ĭ
	0x012E: "I",  // Į
	0x012F: "i",  // į
	0x0130: "I",  // İ
	0x0131: "i",  // ı
	0x0132: "IJ", // Ĳ
	0x0133: "ij", // ĳ
	0x0134: "J",  // Ĵ
	0x0135: "j",  // ĵ
	0x0136: "K",  // Ķ
	0x0137: "k",  // ķ
	0x0138: "k",  // ĸ
	0x0139: "L",  // Ĺ
	0x013A: "l",  // ĺ
	0x013B: "L",  // Ļ
	0x013C: "l",  // ļ
	0x013D: "L",  // Ľ
	0x013E: "l",  // ľ
	0x013F: "L",  // Ŀ
	0x0140: "l",  // ŀ
	0x0141: "L",  // Ł
	0x0142: "l",  // ł
	0x0143: "N",  // Ń
	0x0144: "n",  // ń
	0x0145: "N",  // Ņ
	0x0146: "n",  // ņ
	0x0147: "N",  // Ň
	0x0148: "n",  // ň
	0x0149: "'n", // ŉ
	0x014A: "NG", // Ŋ
	0x014B: "ng", // ŋ
	0x014C: "O",  // Ō
	0x014D: "o",  // ō
	0x014E: "O",  // Ŏ
	0x014F: "o",  // ŏ
	0x0150: "O",  // Ő
	0x0151: "o",  // ő
	0x0152: "OE", // Œ
	0x0153: "oe", // œ
	0x0154: "R",  // Ŕ
	0x0155: "r",  // ŕ
	0x0156: "R",  // Ŗ
	0x0157: "r",  // ŗ
	0x0158: "R",  // Ř
	0x0159: "r",  // ř
	0x015A: "S",  // Ś
	0x015B: "s",  // ś
	0x015C: "S",  // Ŝ
	0x015D: "s",  // ŝ
	0x015E: "S",  // Ş
	0x015F: "s",  // ş
	0x0160: "S",  // Š
	0x0161: "s",  // š
	0x0162: "T",  // Ţ
	0x0163: "t",  // ţ
	0x0164: "T",  // Ť
	0x0165: "t",  // ť
	0x0166: "T",  // Ŧ
	0x0167: "t",  // ŧ
	0x0168: "U",  // Ũ
	0x0169: "u",  // ũ
	0x016A: "U",  // Ū
	0x016B: "u",  // ū
	0x016C: "U",  // Ŭ
	0x016D: "u",  // ŭ
	0x016E: "U",  // Ů
	0x016F: "u",  // ů
	0x0170: "U",  // Ű
	0x0171: "u",  // ű
	0x0172: "U",  // Ų
	0x0173: "u",  // ų
	0x0174: "W",  // Ŵ
	0x0175: "w",  // ŵ
	0x0176: "Y",  // Ŷ
	0x0177: "y",  // ŷ
	0x0178: "Y",  // Ÿ
	0x0179: "Z",  // Ź
	0x017A: "z",  // ź
	0x017B: "Z",  // Ż
	0x017C: "z",  // ż
	0x017D: "Z",  // Ž
	0x017E: "z",  // ž
	0x1E9E: "SS", // ẞ
}
