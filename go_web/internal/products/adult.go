package products

import (
	"regexp"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// adultKeywords are AdultKeywordDetector::ADULT_KEYWORD_REGEX's.
var adultKeywords = map[string]bool{}

func init() {
	for _, k := range []string{"futa", "pussy", "bondage", "bdsm", "lewd", "ahegao", "nude", "milking", "topless", "lolita", "lewds",
		"creampie", "dildo", "gape", "semen", "cuckold", "hairjob", "tickling", "hogtied", "uncensored", "thong",
		"pinup", "impregnation", "gagged", "hentai", "squirt", "orgasm", "virginkiller", "abdl", "crotch",
		"breast inflation", "granblue", "lingerie",
		"boudoir", "kink", "shibari", "gutpunch", "gutpunching", "abs punch", "necro",
		"vibrator", "fetish", "nsfw", "footjob", "joi"} {
		adultKeywords[k] = true
	}
}

// adultTokens is TOKENIZATION_REGEX. Ruby first turns every non-letter into a space, which
// changes no token, since tokens are only letters.
var adultTokens = regexp.MustCompile(`(?:[\p{Lu}\p{Lt}]?[\p{Ll}\p{Lm}\p{Lo}]+)|(?:[\p{Lu}\p{Lt}])+`)

// adultText is AdultKeywordDetector.adult?. Ruby's \b counts letters as word characters, so
// a keyword matches whole tokens of the space-joined string, two of them for "abs punch".
func adultText(text string) bool {
	tokens := adultTokens.FindAllString(text, -1)
	for i, t := range tokens {
		tokens[i] = rails.Downcase(t)
	}
	for i, t := range tokens {
		if adultKeywords[t] || i+1 < len(tokens) && adultKeywords[t+" "+tokens[i+1]] {
			return true
		}
	}
	return false
}
