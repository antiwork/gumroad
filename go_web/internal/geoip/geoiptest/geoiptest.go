// Package geoiptest writes MaxMind City databases for tests.
package geoiptest

import (
	"net"
	"os"
	"path/filepath"
	"testing"

	"github.com/maxmind/mmdbwriter"
	"github.com/maxmind/mmdbwriter/mmdbtype"
)

// WriteDatabase builds a small GeoIP2-City-shaped database: 81.2.69.0/24 is a full GB
// record and 2001:db8::/32 is a JP country with no English name.
func WriteDatabase(t testing.TB) string {
	t.Helper()
	tree, err := mmdbwriter.New(mmdbwriter.Options{DatabaseType: "GeoIP2-City", RecordSize: 28, IncludeReservedNetworks: true})
	if err != nil {
		t.Fatal(err)
	}
	insert := func(cidr string, data mmdbtype.Map) {
		_, network, err := net.ParseCIDR(cidr)
		if err != nil {
			t.Fatal(err)
		}
		if err := tree.Insert(network, data); err != nil {
			t.Fatal(err)
		}
	}
	insert("81.2.69.0/24", mmdbtype.Map{
		"country": mmdbtype.Map{"iso_code": mmdbtype.String("GB"), "names": mmdbtype.Map{"en": mmdbtype.String("United Kingdom"), "de": mmdbtype.String("Vereinigtes Königreich")}},
		"subdivisions": mmdbtype.Slice{
			mmdbtype.Map{"iso_code": mmdbtype.String("ENG")},
			mmdbtype.Map{"iso_code": mmdbtype.String("WBK")},
		},
		"city":     mmdbtype.Map{"names": mmdbtype.Map{"en": mmdbtype.String("Boxford")}},
		"postal":   mmdbtype.Map{"code": mmdbtype.String("OX1")},
		"location": mmdbtype.Map{"latitude": mmdbtype.Float64(51.75), "longitude": mmdbtype.Float64(-1.25)},
	})
	insert("2001:db8::/32", mmdbtype.Map{
		"country": mmdbtype.Map{"iso_code": mmdbtype.String("JP"), "names": mmdbtype.Map{"ja": mmdbtype.String("日本")}},
	})
	path := filepath.Join(t.TempDir(), "GeoIP2-City.mmdb")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if _, err := tree.WriteTo(f); err != nil {
		t.Fatal(err)
	}
	return path
}
