package rails

import "testing"

func uriQuery(s string) *string { return &s }

// URI.parse under uri 1.1.1; nil marks URI::InvalidURIError. Port is the raw port group.
var parseURIResults = map[string]*URI{
	"https://cdn.iframe.ly/embed.js":             {Scheme: "https", Host: "cdn.iframe.ly", HasHost: true, Path: "/embed.js"},
	"//cdn.iframe.ly/embed.js":                   {Scheme: "", Host: "cdn.iframe.ly", HasHost: true, Path: "/embed.js"},
	"https://cdn.iframe.ly/embed.js?api_key=abc": {Scheme: "https", Host: "cdn.iframe.ly", HasHost: true, Path: "/embed.js", Query: uriQuery("api_key=abc")},
	"https://cdn.iframe.ly//embed.js":            {Scheme: "https", Host: "cdn.iframe.ly", HasHost: true, Path: "//embed.js"},
	"HTTP://CDN.IFRAME.LY/abc":                   {Scheme: "http", Host: "CDN.IFRAME.LY", HasHost: true, Path: "/abc"},
	"https://u:p@iframely.net:8080/x#f":          {Scheme: "https", Host: "iframely.net", HasHost: true, Port: "8080", Path: "/x"},
	"cdn.iframe.ly/embed.js":                     {Scheme: "", Path: "cdn.iframe.ly/embed.js"},
	"/embed.js":                                  {Scheme: "", Path: "/embed.js"},
	"":                                           {Scheme: "", Path: ""},
	" https://cdn.iframe.ly/x":                   nil,
	"https://cdn.iframe.ly/a b":                  nil,
	"https://cdn.iframe.ly/é":                    nil,
	"https://cdn.iframe.ly/x?a=%zz":              nil,
	"https://cdn.iframe.ly/x?a=%41&b=\"c\"":      {Scheme: "https", Host: "cdn.iframe.ly", HasHost: true, Path: "/x", Query: uriQuery("a=%41&b=%22c%22")},
	"https://cdn.iframe.ly/x?a\tb":               {Scheme: "https", Host: "cdn.iframe.ly", HasHost: true, Path: "/x", Query: uriQuery("ab")},
	"javascript://cdn.iframe.ly/%0Aalert(1)":     {Scheme: "javascript", Host: "cdn.iframe.ly", HasHost: true, Path: "/%0Aalert(1)"},
	"javascript:alert(1)":                        {Scheme: "javascript", Path: ""},
	"https:":                                     {Scheme: "https", Path: ""},
	"https:/x":                                   {Scheme: "https", Path: "/x"},
	"//":                                         {Scheme: "", Path: ""},
	"///x":                                       {Scheme: "", Path: "/x"},
	"https://[::1]:443/a":                        {Scheme: "https", Host: "[::1]", HasHost: true, Port: "443", Path: "/a"},
	"https://cdn.iframe.ly.:80":                  {Scheme: "https", Host: "cdn.iframe.ly.", HasHost: true, Port: "80", Path: ""},
	"https://cdn.iframe.ly/x#a b":                nil,
	"?q=1":                                       {Scheme: "", Path: "", Query: uriQuery("q=1")},
	"#frag":                                      {Scheme: "", Path: ""},
	"a:b:c":                                      {Scheme: "a", Path: ""},
	"x-y+z.w://host/p":                           {Scheme: "x-y+z.w", Host: "host", HasHost: true, Path: "/p"},
	"//:80":                                      {Scheme: "", Port: "80", Path: ""},
	"//u@":                                       {Scheme: "", Host: "", HasHost: true, Path: ""},
	"//u@/x":                                     {Scheme: "", Host: "", HasHost: true, Path: "/x"},
	"https://":                                   {Scheme: "https", Host: "", HasHost: true, Path: ""},
	"https:///x":                                 {Scheme: "https", Host: "", HasHost: true, Path: "/x"},
	"//?q":                                       {Scheme: "", Path: "", Query: uriQuery("q")},
	"//#f":                                       {Scheme: "", Path: ""},
	"//x":                                        {Scheme: "", Host: "x", HasHost: true, Path: ""},
	"//[::1]":                                    {Scheme: "", Host: "[::1]", HasHost: true, Path: ""},
	"//u@:1/x":                                   {Scheme: "", Host: "", HasHost: true, Port: "1", Path: "/x"},
}

func TestParseURIMatchesURIParse(t *testing.T) {
	for input, want := range parseURIResults {
		got, err := ParseURI(input)
		if want == nil {
			if err == nil {
				t.Errorf("ParseURI(%q) = %+v, want URI::InvalidURIError", input, got)
			}
			continue
		}
		if err != nil {
			t.Errorf("ParseURI(%q) failed: %v", input, err)
			continue
		}
		if got.Scheme != want.Scheme || got.Host != want.Host || got.HasHost != want.HasHost || got.Port != want.Port || got.Path != want.Path ||
			(got.Query == nil) != (want.Query == nil) || got.Query != nil && *got.Query != *want.Query {
			t.Errorf("ParseURI(%q) = %+v, want %+v", input, got, *want)
		}
	}
}
