package web

import "testing"

func TestProductLongURL(t *testing.T) {
	env := &Environment{Protocol: "https", Domain: "gumroad.com", RootDomain: "gumroad.com"}
	dev := &Environment{Protocol: "http", Domain: "localhost:80", RootDomain: "localhost:80"}
	for _, c := range []struct {
		env                 *Environment
		username, permalink string
		want                string
	}{
		{env, "sell_er", "abc", "https://sell-er.gumroad.com/l/abc"},
		{env, "", "abc", "https://gumroad.com/l/abc"},
		{env, "seller", "a b/c?é", "https://seller.gumroad.com/l/a%20b%2Fc%3F%C3%A9"},
		{env, "seller", "-._~!$&'()*+,;=:@", "https://seller.gumroad.com/l/-._~!$&'()*+,;=:@"},
		// url_for drops the scheme's default port.
		{dev, "seller", "abc", "http://seller.localhost/l/abc"},
	} {
		if got := c.env.ProductLongURL(c.username, c.permalink); got != c.want {
			t.Errorf("%q %q: got %s, want %s", c.username, c.permalink, got, c.want)
		}
	}
}
