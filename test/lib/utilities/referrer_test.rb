# frozen_string_literal: true

require "test_helper"

class ReferrerTest < ActiveSupport::TestCase
  test "extract_domain extracts the host from a url" do
    assert_equal "twitter.com", Referrer.extract_domain("http://twitter.com/ads")
  end

  test "extract_domain returns 'direct' when URI parsing raises" do
    URI.stub :parse, ->(_) { raise URI::InvalidURIError } do
      assert_equal "direct", Referrer.extract_domain("invalid")
    end
  end

  test "extract_domain returns 'direct' when url is nil" do
    assert_equal "direct", Referrer.extract_domain(nil)
  end

  test "extract_domain returns 'direct' when url is the literal string 'direct'" do
    assert_equal "direct", Referrer.extract_domain("direct")
  end

  test "extract_domain returns 'direct' when the parsed host is blank" do
    # URI.parse('file:///').host == ""
    assert_equal "direct", Referrer.extract_domain("file:///C:/Users/FARHAN/Downloads/New%20folder/ok.html")
  end

  test "extract_domain handles url-escaped urls" do
    assert_equal "graceburrowes.com", Referrer.extract_domain(CGI.escape("http://graceburrowes.com/"))
  end

  test "extract_domain handles japanese characters that may cause UTF-8 errors" do
    url = "http://www2.mensnet.jp/navi/ps_search.cgi?word=%8B%D8%93%F7&cond=0&metasearch=&line=&indi=&act=search"
    assert_equal "www2.mensnet.jp", Referrer.extract_domain(url)
  end

  test "extract_domain handles exotic unicode characters" do
    assert_equal "google.com", Referrer.extract_domain("http://google.com/search?query=☃")
  end

  test "extract_domain handles unicode characters in escaped urls" do
    assert_equal "google.com", Referrer.extract_domain(CGI.escape("http://google.com/search?query=☃"))
  end

  test "extract_domain catches Encoding::CompatibilityError when applicable" do
    str = "http://動画素材怎么解决的!`.com/blog/%E3%83%95%E3%83%AA%E3%83%BC%E5%8B%95%E7%94%BB%E7%B4%A0%E6%9D%90%E8%BF%BD%E5%8A%A0%EF%"
    str += "BC%88%E5%8B%95%E7%94%BB%E7%B4%A0%E6%9D%90-com%EF%BC%89%EF%BC%86-4k2k%E5%8B%95%E7%94%BB%E7%B4%A0%E6%9D%90%E3%82%92/"
    assert_equal "direct", Referrer.extract_domain(str.force_encoding("ASCII-8BIT"))
  end

  test "extract_domain handles whitespace inside query strings" do
    assert_equal "bing.com", Referrer.extract_domain("http://www.bing.com/search?q=shady%20record")
  end
end
