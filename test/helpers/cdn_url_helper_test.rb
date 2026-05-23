# frozen_string_literal: true

require "test_helper"

class CdnUrlHelperTest < ActionView::TestCase
  test "cdn_url_for rewrites an S3 url through the CDN_URL_MAP" do
    original = CDN_URL_MAP.dup
    CDN_URL_MAP.replace({ "#{AWS_S3_ENDPOINT}/gumroad/" => "https://static-2.gumroad.com/res/gumroad/" })

    s3_url = "#{AWS_S3_ENDPOINT}/gumroad/sample.png"
    assert_equal "https://static-2.gumroad.com/res/gumroad/sample.png", cdn_url_for(s3_url)
  ensure
    CDN_URL_MAP.replace(original) if original
  end
end
