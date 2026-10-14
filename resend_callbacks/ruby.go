package main

import (
	"encoding/base64"
	"errors"
	"strconv"
	"strings"
)

// Helpers that reproduce the Ruby semantics the ported Rails code relies on.

// blank mirrors ActiveSupport's String#blank? for ASCII input.
func blank[T string | []byte](s T) bool {
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case ' ', '\t', '\n', '\v', '\f', '\r':
		default:
			return false
		}
	}
	return true
}

// rubyToI mirrors String#to_i: optional leading whitespace and sign, then the
// longest run of digits (single underscores allowed between them), else 0.
func rubyToI(s string) int64 {
	s = strings.TrimLeft(s, " \t\n\v\f\r")
	sign := int64(1)
	if s != "" && (s[0] == '+' || s[0] == '-') {
		if s[0] == '-' {
			sign = -1
		}
		s = s[1:]
	}
	var digits strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= '0' && c <= '9' {
			digits.WriteByte(c)
			continue
		}
		if c == '_' && digits.Len() > 0 && i+1 < len(s) && s[i+1] >= '0' && s[i+1] <= '9' {
			continue
		}
		break
	}
	n, err := strconv.ParseInt(digits.String(), 10, 64)
	if err != nil {
		return 0
	}
	return sign * n
}

// rubySplit mirrors String#split with a string separator: trailing empty fields are dropped.
func rubySplit(s, sep string) []string {
	parts := strings.Split(s, sep)
	for len(parts) > 0 && parts[len(parts)-1] == "" {
		parts = parts[:len(parts)-1]
	}
	return parts
}

// strictDecode64 mirrors Base64.strict_decode64, which rejects the line breaks Go's
// decoder would skip.
func strictDecode64(s string) ([]byte, error) {
	if strings.ContainsAny(s, "\r\n") {
		return nil, errors.New("line break in base64")
	}
	return base64.StdEncoding.Strict().DecodeString(s)
}
