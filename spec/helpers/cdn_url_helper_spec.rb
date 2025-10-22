# frozen_string_literal: true

require "spec_helper"

describe CdnUrlHelper do
  before do
    stub_const("CDN_URL_MAP", { "#{AWS_S3_ENDPOINT}/gumroad/" => "https://static-2.gumroad.com/res/gumroad/" })
  end

  describe "#cdn_url_for" do
    it "returns CDN URL" do
      s3_url =  "#{AWS_S3_ENDPOINT}/gumroad/sample.png"

      expect(cdn_url_for(s3_url)).to eq "https://static-2.gumroad.com/res/gumroad/sample.png"
    end
  end
end
