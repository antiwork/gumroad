package inertia

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// production is how config/initializers set these in production.
var production = DefaultMeta{
	Title:                  "Gumroad",
	Environment:            "production",
	FacebookAppID:          "149071038533330",
	StripePublicKey:        "pk_live_Db80xIzLPWhKo1byPrnERmym",
	StripeAPIVersion:       "2023-10-16; risk_in_requirements_beta=v1; retrieve_tax_forms_beta=v1;",
	AssetHost:              "https://assets.gumroad.com",
	AnalyticsByEnvironment: true,
}

// The fixture is _inertia_meta from a production Rails poll by a signed-in user with no
// seller of their own switched in, with the masked token and the user id replaced.
func TestDefaultTagsAreTheMetaRailsSent(t *testing.T) {
	raw, err := os.ReadFile("testdata/production_poll_meta.json")
	if err != nil {
		t.Fatal(err)
	}
	var want any
	json.Unmarshal(raw, &want)
	got := rails.EncodeJSON(production.Tags(Viewer{CSRFToken: "<MASKED>", HasSeller: true, LoggedInUserID: "1234567890123"}).JSON())
	var gotValue any
	json.Unmarshal([]byte(got), &gotValue)
	wantJSON, _ := json.Marshal(want)
	gotJSON, _ := json.Marshal(gotValue)
	if string(gotJSON) != string(wantJSON) {
		t.Fatalf("got\n%s\nwant\n%s", got, raw)
	}
	// Key order is part of the JSON the client receives.
	if got != rails.EncodeJSON(decodeOrdered(t, raw)) {
		t.Errorf("same tags, different key order:\n%s", got)
	}
}

func decodeOrdered(t *testing.T, raw []byte) any {
	v, err := rails.ParseJSON(raw)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

func TestAnalyticsFollowTheCurrentSeller(t *testing.T) {
	for _, c := range []struct {
		meta   DefaultMeta
		viewer Viewer
		want   string
	}{
		{production, Viewer{}, "true"},
		{production, Viewer{HasSeller: true}, "true"},
		{production, Viewer{HasSeller: true, SellerDisablesAnalytics: true}, "false"},
		{DefaultMeta{AnalyticsByEnvironment: false}, Viewer{HasSeller: true}, "false"},
		{DefaultMeta{AnalyticsByEnvironment: false}, Viewer{SellerDisablesAnalytics: true}, "true"},
	} {
		tags := c.meta.Tags(c.viewer)
		if got := tags.tags["meta-property-gr-fb_pixel-enabled"].data[1].Value; got != c.want {
			t.Errorf("%+v, env analytics %v: %s, want %s", c.viewer, c.meta.AnalyticsByEnvironment, got, c.want)
		}
	}
}

func TestMetaTagHeadKeysAndJSON(t *testing.T) {
	for _, c := range []struct {
		tag  MetaTag
		want string
	}{
		{NewMetaTag("", "", "", Attr{Key: "title", Value: "x"}), `{"tagName":"title","headKey":"title","innerContent":"x"}`},
		{NewMetaTag("", "", "", Attr{Key: "property", Value: "og:image:alt"}, Attr{Key: "content", Value: "a"}), `{"tagName":"meta","headKey":"meta-property-og-image-alt","property":"og:image:alt","content":"a"}`},
		{NewMetaTag("", "", "", Attr{Key: "name", Value: "x"}, Attr{Key: "content", Value: " "}), `{"tagName":"meta","headKey":"meta-name-x","name":"x"}`},
		{NewMetaTag("", "", "", Attr{Key: "http_equiv", Value: "Refresh"}, Attr{Key: "content", Value: "1"}), `{"tagName":"meta","headKey":"meta-http_equiv-refresh","httpEquiv":"Refresh","content":"1"}`},
		{NewMetaTag("link", "", "", Attr{Key: "rel", Value: "x"}, Attr{Key: "href", Value: "/y"}), `{"tagName":"link","headKey":"link-` + NewMetaTag("link", "", "", Attr{Key: "href", Value: "/y"}, Attr{Key: "rel", Value: "x"}).digest() + `","rel":"x","href":"/y"}`},
		{NewMetaTag("style", "custom_styles", "", Attr{Key: "inner_content", Value: "a<b"}), `{"tagName":"style","headKey":"custom_styles","innerContent":"a\u003cb"}`},
	} {
		if got := rails.EncodeJSON(c.tag.JSON()); got != c.want {
			t.Errorf("got  %s\nwant %s", got, c.want)
		}
	}
	tags := NewMetaTags()
	tags.Set(NewMetaTag("", "", "", Attr{Key: "title", Value: "first"}))
	tags.Set(NewMetaTag("", "", "", Attr{Key: "name", Value: "a"}, Attr{Key: "content", Value: "1"}))
	tags.Set(NewMetaTag("", "", "", Attr{Key: "title", Value: "second"}))
	if got := rails.EncodeJSON(tags.JSON()); got != `[{"tagName":"title","headKey":"title","innerContent":"second"},{"tagName":"meta","headKey":"meta-name-a","name":"a","content":"1"}]` {
		t.Errorf("a replacement keeps its place: %s", got)
	}
}
