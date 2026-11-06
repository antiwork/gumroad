# frozen_string_literal: true

# Writes public_suffix_names.json.gz: CustomDomain.find_by_host's names for hosts built from
# every rule in the gem's list, as Rails reads Puma's binary Host header.
#   ruby generate_public_suffix_names.rb | gzip -9 -n > public_suffix_names.json.gz
require "json"
gem "public_suffix", "5.1.1"
require "public_suffix"

def names(host)
  host = host.b
  return nil unless PublicSuffix.valid?(host)
  parsed = PublicSuffix.parse(host)
  names = parsed.trd.nil? || parsed.trd == "www" ? [parsed.domain, "www.#{parsed.domain}"] : [host]
  names.map { _1.dup.force_encoding(Encoding::UTF_8) }
end

list = File.read(File.join(Gem.loaded_specs["public_suffix"].full_gem_path, "data/list.txt"))
hosts = list.each_line.map(&:strip).reject { _1.empty? || _1.start_with?("//") }.flat_map do |rule|
  suffix = rule.delete_prefix("*.").delete_prefix("!")
  ["", "shop.", "www.shop.", "a.b.shop.", *("x.shop." if rule.start_with?("*."))].map { "#{_1}#{suffix}" }
end
hosts += ["Example.COM", "example.com.", "example.com..", " example.com ", "\0example.com", "www.example.com", "WWW.Example.com",
          "a.www.example.com", "localhost", "127.0.0.1", "[::1]", ".example.com", "http://example.com", "", ".", "..", "a..b.com",
          "a.b..com", "www..example.com", "example", "xn--fiqs8s.cn", "例子.公司.cn", "shop.blogspot.com", "www.blogspot.com",
          "a.b.c.d.e.example.co.uk", "Shop.MyShopify.Com", "x.www.ck", "www.ck", "a.www.ck", "b.ck", "a.b.ck", "www.foo..ck",
          "İnstagram.com", "ÉXAMPLE.com", "a.kawasaki.jp", "city.kawasaki.jp", "shop_1.example.com", "a*b.com", "%41.com"]
puts JSON.generate(hosts.uniq.map { [_1, names(_1)] })
