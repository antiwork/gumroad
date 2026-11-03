// Package geoip is lib/utilities/geo_ip.rb over a MaxMind City database.
package geoip

import (
	"net/netip"
	"strings"

	"github.com/oschwald/maxminddb-golang/v2"
)

// Result is the part of GeoIp::Result the ported actions read; a nil field is Ruby's nil.
// Rails never has latitude or longitude: santitize_string calls #encode on a Float, which
// #try turns into nil.
type Result struct {
	CountryName *string
	CountryCode *string
	// RegionName is the most specific subdivision's ISO code, as geo_ip.rb notes.
	RegionName *string
}

type record struct {
	Country struct {
		IsoCode *string `maxminddb:"iso_code"`
		Names   struct {
			En *string `maxminddb:"en"`
		} `maxminddb:"names"`
	} `maxminddb:"country"`
	Subdivisions []struct {
		IsoCode *string `maxminddb:"iso_code"`
	} `maxminddb:"subdivisions"`
}

// Reader is GEOIP. A nil *Reader is config/initializers/geoip.rb without the file: every
// lookup is nil.
type Reader struct {
	db *maxminddb.Reader
}

func Open(path string) (*Reader, error) {
	db, err := maxminddb.Open(path)
	if err != nil {
		return nil, err
	}
	return &Reader{db: db}, nil
}

func (r *Reader) Close() error {
	if r == nil {
		return nil
	}
	return r.db.Close()
}

// Lookup is GeoIp.lookup(ip): nil for an unparseable or unknown address, where Rails
// rescues the reader's error.
func (r *Reader) Lookup(ip string) *Result {
	if r == nil {
		return nil
	}
	addr, err := netip.ParseAddr(ip)
	if err != nil {
		return nil
	}
	found := r.db.Lookup(addr.Unmap())
	if !found.Found() {
		return nil
	}
	var rec record
	if err := found.Decode(&rec); err != nil {
		return nil
	}
	// The reader's #name with its default locales, ["en"].
	result := &Result{
		CountryName: sanitize(rec.Country.Names.En),
		CountryCode: sanitize(rec.Country.IsoCode),
	}
	if n := len(rec.Subdivisions); n > 0 {
		result.RegionName = sanitize(rec.Subdivisions[n-1].IsoCode)
	}
	return result
}

// sanitize is santitize_string's encode("UTF-8", invalid: :replace, replace: "?").
func sanitize(s *string) *string {
	if s == nil {
		return nil
	}
	v := strings.ToValidUTF8(*s, "?")
	return &v
}
