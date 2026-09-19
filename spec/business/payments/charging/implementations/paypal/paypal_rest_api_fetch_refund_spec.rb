# frozen_string_literal: true

require "spec_helper"

# No VCR: these examples stub the HTTP client, so nothing leaves the process.
describe PaypalRestApi do
  let(:api_object) { PaypalRestApi.new }
  let(:http_client) { instance_double(PayPal::PayPalHttpClient) }

  before do
    allow(PayPal::PayPalHttpClient).to receive(:new).and_return(http_client)
  end

  describe "#fetch_refund" do
    it "reads the refund for the merchant the refund belongs to" do
      merchant_account = build(:merchant_account_paypal, charge_processor_merchant_id: "MN7CSWD6RCNJ8")
      expect(http_client).to receive(:execute) do |request|
        expect(request.verb).to eq("GET")
        expect(request.path).to eq("/v2/payments/refunds/8SL48586NM399494P")
        expect(request.headers["Paypal-Auth-Assertion"]).to eq(
          "#{Base64.strict_encode64({ alg: 'none' }.to_json)}.#{Base64.strict_encode64({ payer_id: 'MN7CSWD6RCNJ8', iss: PAYPAL_PARTNER_CLIENT_ID }.to_json)}."
        )
        OpenStruct.new(status_code: 200, result: OpenStruct.new(status: "COMPLETED"))
      end

      api_object.fetch_refund(refund_id: "8SL48586NM399494P", merchant_account:)
    end

    it "reads without an auth assertion when the merchant is unknown" do
      expect(http_client).to receive(:execute) do |request|
        expect(request.headers["Paypal-Auth-Assertion"]).to be_nil
        OpenStruct.new(status_code: 200, result: OpenStruct.new(status: "PENDING"))
      end

      api_object.fetch_refund(refund_id: "8SL48586NM399494P")
    end
  end
end