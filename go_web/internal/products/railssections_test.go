package products

import (
	"encoding/json"
	"math/big"
	"reflect"
	"testing"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/railscache"
)

// JSON's numbers load as Ruby's Integer, a Bignum past int64, and Float. One past a Float's range
// goes to Rails, though MySQL's JSON type never stores one.
func TestMarshalJSON(t *testing.T) {
	// The largest integer MySQL's JSON type keeps as one.
	huge, _ := new(big.Int).SetString("18446744073709551615", 10)
	for text, want := range map[string]any{
		`{"a":[1,-0,2.50,1e2,"é",null,true]}`: railscache.Hash{{Key: "a", Value: []any{int64(1), int64(0), 2.5, 100.0, "é", nil, true}}},
		`18446744073709551615`:                huge,
	} {
		parsed, err := rails.ParseJSON([]byte(text))
		if err != nil {
			t.Fatal(err)
		}
		got, ok := marshalJSON(parsed)
		if !ok || !reflect.DeepEqual(got, want) {
			t.Errorf("%s: %#v %v", text, got, ok)
		}
	}
	if _, ok := marshalJSON(json.Number("1e400")); ok {
		t.Error("an overflowing Float")
	}
}

// The key Rails gave a production product's three sections, the latest saved at 18:33:59.322996.
func TestProductSectionsCacheKey(t *testing.T) {
	latest, err := time.Parse(time.RFC3339Nano, "2026-11-05T18:33:59.322996Z")
	if err != nil {
		t.Fatal(err)
	}
	const want = "seller_profile_sections/query-2cf31ea7e2d992eb12843b982d2b651d-3-20261105183359322996"
	if got := productSectionsCacheKey(12_710_316, 3, db.NullTime{Time: latest, Valid: true}); got != want {
		t.Errorf("%s\nwant %s", got, want)
	}
}
