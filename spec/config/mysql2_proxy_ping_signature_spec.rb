# frozen_string_literal: true

require "spec_helper"

describe "mysql2 proxy Ping signature routing" do
  include_context "real mysql2 proxy pools"

  it "signs with the primary's secret while the replica still holds the one before a rotation" do
    seller, setting = primary_setup do
      user = create(:user, notification_endpoint: "https://example.com")
      [user, user.create_ping_signing_setting!(secret: "before-rotation")]
    end
    [seller, setting].each { replicate_record(_1) }
    primary_setup { setting.update!(secret: "after-rotation") }
    header = nil
    allow(SsrfFilter).to receive(:post) do |_url, options|
      header = options[:headers]["X-Gumroad-Signature"]
      Net::HTTPOK.new("1.1", "200", "OK")
    end

    reads = record_serving_reads do
      PostToIndividualPingEndpointWorker.new.perform("https://example.com", { "a" => 1 }, Mime[:url_encoded_form].to_s, seller.id)
    end

    timestamp = header[/\At=(\d+),/, 1]
    expect(header).to eq("t=#{timestamp},v1=#{OpenSSL::HMAC.hexdigest("SHA256", "after-rotation", "#{timestamp}.a=1")}")
    expect(reads.filter_map { |sql, pool| pool if sql.include?("`ping_signing_settings`") }).to eq(["primary"])
    expect(serving_pool).to eq("replica")
  end
end
