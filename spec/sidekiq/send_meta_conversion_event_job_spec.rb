# frozen_string_literal: true

require "spec_helper"

describe SendMetaConversionEventJob do
  include CurrencyHelper

  let(:seller) { create(:user, facebook_pixel_id: "1056510450054835") }
  let(:product) { create(:product, user: seller, price_cents: 20_00) }
  let(:purchase) do
    create(
      :purchase,
      link: product,
      seller:,
      email: " Buyer@Example.com ",
      ip_address: "203.0.113.9",
      ip_country: "United States",
      country: "United States",
      succeeded_at: 1.hour.ago
    )
  end
  let(:endpoint) { "https://graph.facebook.com/v27.0/#{seller.facebook_pixel_id}/events" }
  let(:context) { { user_agent: "Mozilla/5.0 (Macintosh)", base_url: "https://shop.example.com" } }
  let(:request_body) { {} }

  before do
    MerchantAccount.find_or_create_by!(user_id: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id) do |merchant_account|
      merchant_account.charge_processor_alive_at = Time.current
    end
    Feature.activate_user(:meta_conversions_api, seller)
    seller.create_meta_conversions_setting!(access_token: "seller-token")
    MetaConversions::PurchaseContext.save_for([purchase], **context)
    allow(Rails.logger).to receive(:info)
  end

  def stub_meta(status: 200, body: { events_received: 1 }.to_json, captured: request_body)
    stub_request(:post, endpoint).with { |request| captured.replace(JSON.parse(request.body)); true }
      .to_return(status:, body:, headers: { "Content-Type" => "application/json" })
  end

  def perform
    described_class.new.perform(purchase.id)
  end

  context "when the send succeeds" do
    before { stub_meta }

    it "posts one Purchase event for the purchase" do
      perform

      event = request_body["data"].first
      expect(event).to include(
        "event_name" => "Purchase",
        "event_id" => purchase.external_id,
        "event_time" => purchase.succeeded_at.to_i,
        "action_source" => "website",
        "event_source_url" => "https://shop.example.com",
        "data_processing_options" => ["LDU"],
        "data_processing_options_country" => 0,
        "data_processing_options_state" => 0
      )
    end

    it "sends the hashed, trimmed, downcased buyer email, the IP address and the user agent" do
      perform

      expect(request_body["data"].first["user_data"]).to eq(
        "em" => [Digest::SHA256.hexdigest("buyer@example.com")],
        "client_ip_address" => "203.0.113.9",
        "client_user_agent" => "Mozilla/5.0 (Macintosh)"
      )
    end

    it "keeps the token out of the request URL and in the body" do
      perform

      expect(request_body["access_token"]).to eq("seller-token")
      expect(a_request(:post, endpoint).with { |request| request.uri.query.nil? }).to have_been_made
    end

    it "keeps the product, the buyer name and the browser cookie ids out of the payload" do
      perform

      event = request_body["data"].first
      expect(event.keys).to contain_exactly(
        "event_name", "event_time", "event_id", "action_source", "event_source_url",
        "user_data", "custom_data", "data_processing_options",
        "data_processing_options_country", "data_processing_options_state"
      )
      expect(event["custom_data"].keys).to contain_exactly("value", "currency")
      expect(request_body["data"].first["user_data"]).not_to have_key("fbp")
    end

    it "matches the value and currency of the browser Purchase event" do
      perform

      browser = PurchaseSellerAnalyticsPresenter.new(purchase).props[:purchase_event]
      browser_value = browser[:value].to_f / (is_currency_type_single_unit?(browser[:currency]) ? 1 : 100)

      expect(request_body["data"].first["custom_data"]).to eq(
        "value" => browser_value,
        "currency" => browser[:currency].upcase
      )
    end

    it "matches the browser value for a zero-decimal currency" do
      jpy_purchase = create(
        :purchase,
        link: create(:product, user: seller, price_cents: 20_00, price_currency_type: "jpy"),
        seller:,
        displayed_price_currency_type: "jpy",
        displayed_price_cents: 20_00,
        ip_country: "United States",
        succeeded_at: 1.hour.ago
      )
      MetaConversions::PurchaseContext.save_for([jpy_purchase], **context)

      described_class.new.perform(jpy_purchase.id)

      browser = PurchaseSellerAnalyticsPresenter.new(jpy_purchase).props[:purchase_event]
      expect(request_body["data"].first["custom_data"]).to eq(
        "value" => 2000.0,
        "currency" => "JPY"
      )
      expect(request_body["data"].first["custom_data"]["value"]).to eq(browser[:value])
    end

    it "logs the outcome" do
      perform

      expect(Rails.logger).to have_received(:info).with(
        "MetaConversions outcome=sent reason= purchase_id=#{purchase.id} " \
        "seller_id=#{seller.id} http_status=200 fb_error_code= fbtrace_id="
      )
    end
  end

  context "when the buyer arrived from a Meta ad" do
    before do
      purchase.update!(url_parameters: { "fbclid" => "IwAR2F4-dbP0l7Mn1IawQQ" })
      stub_meta
    end

    it "sends the click id in Meta's fbc format" do
      perform

      expect(request_body["data"].first["user_data"]["fbc"]).to eq(
        "fb.1.#{(purchase.created_at.to_f * 1000).round}.IwAR2F4-dbP0l7Mn1IawQQ"
      )
    end
  end

  context "when the buyer did not arrive from a Meta ad" do
    before { stub_meta }

    it "sends no fbc" do
      perform

      expect(request_body["data"].first["user_data"]).not_to have_key("fbc")
    end
  end

  context "when Meta rejects the token" do
    before do
      stub_meta(
        status: 400,
        body: {
          error: {
            message: "Error validating access token: The session has been invalidated",
            type: "OAuthException",
            code: 190,
            fbtrace_id: "A1b2C3"
          }
        }.to_json
      )
    end

    it "marks the token as rejected and stops sending for that seller" do
      perform

      expect(seller.meta_conversions_setting.reload.token_rejected_at).to be_present
      expect(MetaConversions::Eligibility.seller_skip_reason(seller)).to eq(:token_rejected)
    end

    it "does not raise, so the job is not retried" do
      expect { perform }.not_to raise_error
    end

    it "logs the rejection with the trace id" do
      perform

      expect(Rails.logger).to have_received(:info).with(
        "MetaConversions outcome=rejected reason=token purchase_id=#{purchase.id} " \
        "seller_id=#{seller.id} http_status=400 fb_error_code=190 fbtrace_id=A1b2C3"
      )
    end

    it "leaves a token the seller replaced mid-request alone" do
      stub_request(:post, endpoint).to_return do
        MetaConversionsSetting.find_by(user: seller).update!(access_token: "replacement-token")
        { status: 400, body: { error: { message: "Invalid OAuth access token", code: 190 } }.to_json }
      end

      perform

      setting = MetaConversionsSetting.find_by(user: seller)
      expect(setting.access_token).to eq("replacement-token")
      expect(setting.token_rejected_at).to be_nil
      expect(MetaConversions::Eligibility.seller_skip_reason(seller)).to be_nil
    end
  end

  context "when Meta rejects the event for another reason" do
    before do
      stub_meta(status: 400, body: { error: { message: "Invalid parameter", type: "GraphMethodException", code: 100 } }.to_json)
    end

    it "logs the rejection, leaves the token alone and does not retry" do
      expect { perform }.not_to raise_error

      expect(seller.meta_conversions_setting.reload.token_rejected_at).to be_nil
      expect(Rails.logger).to have_received(:info).with(/outcome=rejected reason=graph_error/)
    end
  end

  context "when Meta is unreachable or overloaded" do
    it "raises so Sidekiq retries a 5xx" do
      stub_meta(status: 503, body: "")

      expect { perform }.to raise_error(described_class::SendFailed)
    end

    it "raises so Sidekiq retries a rate limit" do
      stub_meta(status: 429, body: { error: { message: "Rate limit", code: 4 } }.to_json)

      expect { perform }.to raise_error(described_class::SendFailed)
    end

    it "raises so Sidekiq retries a timeout" do
      stub_request(:post, endpoint).to_timeout

      expect { perform }.to raise_error(described_class::SendFailed)
    end

    it "logs the attempt as a retry" do
      stub_meta(status: 503, body: "")

      expect { perform }.to raise_error(described_class::SendFailed)
      expect(Rails.logger).to have_received(:info).with(/outcome=retry reason=graph_error .*http_status=503/)
    end
  end

  context "when a gate no longer passes" do
    it "sends nothing when no context was saved for the purchase" do
      $redis.del(RedisKey.meta_conversions_purchase_context(purchase.id))

      expect { perform }.not_to raise_error
      expect(a_request(:post, endpoint)).not_to have_been_made
      expect(Rails.logger).to have_received(:info).with(/outcome=skipped reason=no_context/)
    end

    it "sends nothing when the seller's token was rejected in the meantime" do
      seller.meta_conversions_setting.update!(token_rejected_at: Time.current)

      expect { perform }.not_to raise_error
      expect(a_request(:post, endpoint)).not_to have_been_made
      expect(Rails.logger).to have_received(:info).with(/outcome=skipped reason=token_rejected/)
    end

    it "sends nothing for a buyer in a restricted country" do
      purchase.update!(ip_country: "Ireland")

      expect { perform }.not_to raise_error
      expect(a_request(:post, endpoint)).not_to have_been_made
      expect(Rails.logger).to have_received(:info).with(/outcome=skipped reason=restricted_country/)
    end

    it "sends nothing when the purchase row is gone" do
      purchase_id = purchase.id
      purchase.destroy!

      expect { described_class.new.perform(purchase_id) }.not_to raise_error
      expect(a_request(:post, endpoint)).not_to have_been_made
    end
  end
end
