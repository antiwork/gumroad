# frozen_string_literal: true

require "spec_helper"

describe Referrer do
  describe ".extract_domain" do
    it "extracts domain from url" do
      expect(Referrer.extract_domain("http://twitter.com/ads")).to eq "twitter.com"
    end

    it "returns direct if url is invalid" do
      allow(URI).to receive(:parse).and_raise(URI::InvalidURIError)
      expect(Referrer.extract_domain("invalid")).to eq "direct"
    end

    it "returns direct if url is nil" do
      expect(Referrer.extract_domain(nil)).to eq "direct"
    end

    it "returns direct if url is direct" do
      expect(Referrer.extract_domain("direct")).to eq "direct"
    end

    it "returns direct if parsed host is blank" do
      # URI.parse('file:///').host == ""
      expect(Referrer.extract_domain("file:///C:/Users/FARHAN/Downloads/New%20folder/ok.html")).to eq "direct"
    end

    it "still works even with url escaped urls" do
      expect(Referrer.extract_domain(CGI.escape("http://graceburrowes.com/"))).to eq "graceburrowes.com"
    end

    it "still works even with japanese characters that may cause UTF-8 errors" do
      expect(Referrer.extract_domain("http://www2.mensnet.jp/navi/ps_search.cgi?word=%8B%D8%93%F7&cond=0&metasearch=&line=&indi=&act=search"))
        .to eq "www2.mensnet.jp"
    end

    it "still works even with exotic unicode characters" do
      expect(Referrer.extract_domain("http://google.com/search?query=☃")).to eq "google.com"
    end

    it "still works even with exotic unicode characters and if the url is escaped" do
      expect(Referrer.extract_domain(CGI.escape("http://google.com/search?query=☃"))).to eq "google.com"
    end

    it "catches Encoding::CompatibilityError when applicable" do
      str = "http://動画素材怎么解决的!`.com/blog/%E3%83%95%E3%83%AA%E3%83%BC%E5%8B%95%E7%94%BB%E7%B4%A0%E6%9D%90%E8%BF%BD%E5%8A%A0%EF%"
      str += "BC%88%E5%8B%95%E7%94%BB%E7%B4%A0%E6%9D%90-com%EF%BC%89%EF%BC%86-4k2k%E5%8B%95%E7%94%BB%E7%B4%A0%E6%9D%90%E3%82%92/"
      expect(Referrer.extract_domain(str.force_encoding("ASCII-8BIT"))).to eq "direct"
    end

    it "handles whitespace properly" do
      url = "http://www.bing.com/search?q=shady%20record"
      expect(Referrer.extract_domain(url)).to eq("bing.com")
    end
  end
end
