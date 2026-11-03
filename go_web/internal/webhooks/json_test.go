package webhooks

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
)

func sidekiqMarshal(v any) (string, error) {
	out, err := sidekiq.Marshal(v)
	return string(out), err
}

// JSON.parse then JSON.generate, as Ruby gives them for the same bodies.
func TestParseJSONKeepsRubysOrderAndValues(t *testing.T) {
	cases := map[string]string{
		`{"b":1,"a":2,"b":3}`:                                `{"b":3,"a":2}`,
		`[1,null,{"x":[null]}]`:                              `[1,null,{"x":[null]}]`,
		`{"f":1.50,"e":1e2,"n":12345678901234567890,"z":-0}`: `{"f":1.5,"e":100.0,"n":12345678901234567890,"z":0}`,
		` {"s":"é😀"} `:                                       `{"s":"é😀"}`,
		`{}`:                                                 `{}`,
	}
	for body, want := range cases {
		parsed, loneLow, err := parseJSON([]byte(body))
		if err != nil || loneLow {
			t.Fatalf("parseJSON(%s): %v", body, err)
		}
		if got, err := sidekiqMarshal(parsed); err != nil || got != want {
			t.Errorf("parseJSON(%s) generates %s, %v; want %s", body, got, err, want)
		}
	}
	// A hash past the linear scan still keeps a repeated key in its first place.
	var keys []string
	for _, c := range "abcdefghijklmnopqrst" {
		keys = append(keys, `"`+string(c)+`":1`)
	}
	parsed, _, _ := parseJSON([]byte(`{` + strings.Join(keys, ",") + `,"a":2}`))
	if hash := parsed.(sidekiq.Hash); len(hash) != 20 || hash[0].Key != "a" || hash[0].Value != json.Number("2") {
		t.Fatalf("parsed %v", hash)
	}
}

func TestParseJSONRejectsWhatRubyRejects(t *testing.T) {
	deep := func(n int, inner string) string { return strings.Repeat("[", n) + inner + strings.Repeat("]", n) }
	for name, body := range map[string]string{
		"lone high surrogate":    `{"s":"\ud800"}`,
		"low then high":          `{"s":"\udc00\ud800"}`,
		"high then other escape": `{"s":"\ud800A"}`,
		"101 non-empty levels":   deep(101, "1"),
		"trailing data":          `{} {}`,
		"NaN":                    `{"n":NaN}`,
		"empty":                  ``,
	} {
		if _, _, err := parseJSON([]byte(body)); err == nil {
			t.Errorf("%s: accepted a body JSON.parse rejects", name)
		}
	}
	for name, body := range map[string]string{
		"100 non-empty levels":     deep(100, "1"),
		"empty array at level 101": deep(101, ""),
		"escaped backslash then u": `{"s":"\\ud800"}`,
	} {
		if _, _, err := parseJSON([]byte(body)); err != nil {
			t.Errorf("%s: rejected a body JSON.parse accepts: %v", name, err)
		}
	}
	if _, loneLow, err := parseJSON([]byte(`{"s":"\udc00"}`)); err != nil || !loneLow {
		t.Errorf("an unpaired low surrogate parses, as a string that isn't UTF-8: %v %v", loneLow, err)
	}
}
