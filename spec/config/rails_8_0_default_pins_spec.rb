# frozen_string_literal: true

require "spec_helper"

describe "Rails 8.0 default pins" do
  it "keeps DateTime#to_time on the receiver offset across a US DST boundary" do
    expect(ActiveSupport.to_time_preserves_timezone).to eq(:offset)

    winter = DateTime.new(2026, 1, 15, 12, 0, 0, Rational(9, 24))
    summer = DateTime.new(2026, 7, 15, 12, 0, 0, Rational(9, 24))
    expect(winter.to_time.utc_offset).to eq(9 * 3600)
    expect(summer.to_time.utc_offset).to eq(9 * 3600)

    zone = ActiveSupport::TimeZone["America/New_York"]
    expect(zone.local(2026, 3, 8, 1, 30, 0).to_time.utc_offset).to eq(-5 * 3600)
    expect(zone.local(2026, 3, 8, 3, 30, 0).to_time.utc_offset).to eq(-4 * 3600)
  end

  it "requires both conditional headers to match before treating a response as fresh" do
    expect(ActionDispatch::Http::Cache::Request.strict_freshness).to eq(false)

    response = ActionDispatch::Response.new
    response.etag = "download-v1"
    response.last_modified = Time.utc(2026, 1, 15)

    request = ActionDispatch::Request.new(Rack::MockRequest.env_for("/"))
    request.set_header("HTTP_IF_NONE_MATCH", response.etag)
    request.set_header("HTTP_IF_MODIFIED_SINCE", Time.utc(2025, 12, 1).httpdate)

    expect(request.fresh?(response)).to eq(false)
  end

  it "leaves Regexp.timeout unlimited after boot" do
    expect(Regexp.timeout).to be_nil
  end
end
