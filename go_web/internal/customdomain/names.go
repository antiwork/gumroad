// Package customdomain is CustomDomain.find_by_host's reading of a host, through the
// public_suffix gem Rails uses.
package customdomain

import (
	_ "embed"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// publicSuffixList is the public_suffix 5.1.1 gem's data/list.txt, the version Gemfile.lock pins.
//
//go:embed public_suffix_list.txt
var publicSuffixList string

type suffixKind int

const (
	suffixNormal suffixKind = iota
	suffixWildcard
	suffixException
)

// suffixRule is PublicSuffix::Rule::Entry, keyed by the rule's value.
type suffixRule struct {
	kind   suffixKind
	length int
}

// suffixRules is PublicSuffix::List.default, private section included as Rails reads it.
var suffixRules = parseSuffixList(publicSuffixList)

func parseSuffixList(list string) map[string]suffixRule {
	rules := make(map[string]suffixRule, 10_000)
	for line := range strings.Lines(list) {
		line = rails.Strip(line)
		switch {
		case line == "", strings.HasPrefix(line, "//"):
		case line[0] == '*':
			// Rule.factory's content[2..], with * itself counting as a label.
			value := line[min(2, len(line)):]
			rules[value] = suffixRule{suffixWildcard, strings.Count(value, ".") + 2}
		case line[0] == '!':
			rules[line[1:]] = suffixRule{suffixException, strings.Count(line[1:], ".") + 1}
		default:
			rules[line] = suffixRule{suffixNormal, strings.Count(line, ".") + 1}
		}
	}
	return rules
}

// Names are the custom_domains.domain values CustomDomain.find_by_host reads for host, in its
// order: the apex then www for an apex or www host, else the host itself. None for a host
// PublicSuffix.valid? rejects.
func Names(host string) []string {
	name, ok := normalize(host)
	if !ok {
		return nil
	}
	left, tld, ok := findRule(name).decompose(name)
	if !ok {
		return nil
	}
	parts := rails.Split(left, ".")
	sld, trd := parts[len(parts)-1], parts[:len(parts)-1]
	if len(trd) == 0 || len(trd) == 1 && trd[0] == "www" {
		return []string{sld + "." + tld, "www." + sld + "." + tld}
	}
	return []string{host}
}

// normalize is PublicSuffix.normalize on Puma's binary header string, whose downcase! leaves
// anything but ASCII alone. False where it answers DomainInvalid.
func normalize(host string) (string, bool) {
	name := strings.Map(func(r rune) rune {
		if 'A' <= r && r <= 'Z' {
			return r + 'a' - 'A'
		}
		return r
	}, strings.TrimSuffix(rails.Strip(host), "."))
	return name, name != "" && !strings.HasPrefix(name, ".") && !strings.Contains(name, "://")
}

type matchedRule struct {
	value string
	suffixRule
}

// findRule is List#find: the longest rule matching a run of trailing labels, an exception as
// soon as one follows, else the default "*". A binary string with other than ASCII never
// equals a list entry's UTF-8 key.
func findRule(name string) matchedRule {
	// String#split drops the trailing empty labels a second trailing dot leaves.
	base := strings.TrimRight(name, ".")
	var found *matchedRule
	for i := len(base); ; {
		dot := strings.LastIndexByte(base[:i], '.')
		query := base[dot+1:]
		if rule, ok := suffixRules[query]; ok && isASCII(query) {
			r := matchedRule{query, rule}
			switch {
			case found == nil:
				found = &r
			case r.kind == suffixException:
				return r
			case found.length <= r.length:
				found = &r
			}
		}
		if dot < 0 {
			break
		}
		i = dot
	}
	if found == nil {
		return matchedRule{"", suffixRule{suffixWildcard, 2}}
	}
	return *found
}

func isASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			return false
		}
	}
	return true
}

// decompose is Rule#decompose's /^(.*)\.(suffix)$/: the greedy left part takes everything up to
// the last dot the suffix still matches after.
func (r matchedRule) decompose(name string) (left, right string, ok bool) {
	switch r.kind {
	case suffixWildcard:
		// The suffix is .*?\.value, or anything at all for the default rule.
		for i := len(name) - 1; i >= 0; i-- {
			if name[i] == '.' && (r.value == "" || strings.HasSuffix(name[i+1:], "."+r.value)) {
				return name[:i], name[i+1:], true
			}
		}
		return "", "", false
	case suffixException:
		_, suffix, _ := strings.Cut(r.value, ".")
		return cutSuffix(name, suffix)
	}
	return cutSuffix(name, r.value)
}

func cutSuffix(name, suffix string) (left, right string, ok bool) {
	if left, ok := strings.CutSuffix(name, "."+suffix); ok {
		return left, suffix, true
	}
	return "", "", false
}
