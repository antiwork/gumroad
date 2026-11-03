package geoip

import (
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/geoip/geoiptest"
)

func deref(s *string) string {
	if s == nil {
		return "<nil>"
	}
	return *s
}

func TestLookupReadsTheFieldsGeoIpResultExposes(t *testing.T) {
	reader, err := Open(geoiptest.WriteDatabase(t))
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()

	got := reader.Lookup("81.2.69.160")
	if got == nil {
		t.Fatal("no result")
	}
	for field, pair := range map[string][2]string{
		"country_name": {deref(got.CountryName), "United Kingdom"},
		"country_code": {deref(got.CountryCode), "GB"},
		"region_name":  {deref(got.RegionName), "WBK"},
	} {
		if pair[0] != pair[1] {
			t.Errorf("%s = %q, want %q", field, pair[0], pair[1])
		}
	}

	if got := reader.Lookup("::ffff:81.2.69.1"); got == nil || deref(got.CountryCode) != "GB" {
		t.Error("an IPv4-mapped address must find the IPv4 record")
	}
}

func TestLookupLeavesMissingFieldsNilLikeRuby(t *testing.T) {
	reader, err := Open(geoiptest.WriteDatabase(t))
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()

	got := reader.Lookup("2001:db8::1")
	if got == nil || deref(got.CountryCode) != "JP" {
		t.Fatalf("got %+v", got)
	}
	if got.CountryName != nil || got.RegionName != nil {
		t.Errorf("names without an en entry and absent records must be nil, got %+v", got)
	}
	for _, ip := range []string{"10.0.0.1", "not-an-ip", ""} {
		if reader.Lookup(ip) != nil {
			t.Errorf("Lookup(%q) must be nil", ip)
		}
	}
	var missing *Reader
	if missing.Lookup("81.2.69.160") != nil {
		t.Error("a nil reader is GEOIP without the database file")
	}
}
