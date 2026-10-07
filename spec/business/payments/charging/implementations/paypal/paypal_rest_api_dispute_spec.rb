# frozen_string_literal: true

require "spec_helper"

# No VCR: these examples stub the HTTP client, so nothing leaves the process.
describe PaypalRestApi do
  let(:api_object) { PaypalRestApi.new }
  let(:http_client) { instance_double(PayPal::PayPalHttpClient) }
  let(:merchant_account) { build(:merchant_account_paypal, charge_processor_merchant_id: "MN7CSWD6RCNJ8") }
  let(:assertion) do
    "#{Base64.strict_encode64({ alg: 'none' }.to_json)}.#{Base64.strict_encode64({ payer_id: 'MN7CSWD6RCNJ8', iss: PAYPAL_PARTNER_CLIENT_ID }.to_json)}."
  end

  before do
    allow(PayPal::PayPalHttpClient).to receive(:new).and_return(http_client)
    allow_any_instance_of(PaypalPartnerRestCredentials).to receive(:auth_token).and_return("Bearer test-token")
  end

  describe "#fetch_dispute" do
    it "reads the dispute as the seller's merchant account" do
      expect(http_client).to receive(:execute) do |request|
        expect(request.verb).to eq("GET")
        expect(request.path).to eq("/v1/customer/disputes/PP-R-HDH-1")
        expect(request.headers["Paypal-Auth-Assertion"]).to eq(assertion)
        OpenStruct.new(status_code: 200, result: OpenStruct.new(status: "UNDER_REVIEW"))
      end

      api_object.fetch_dispute(dispute_id: "PP-R-HDH-1", merchant_account:)
    end
  end

  describe "#provide_dispute_supporting_info" do
    it "posts the notes as the multipart `input` part PayPal expects" do
      expect(http_client).to receive(:execute) do |request|
        expect(request.verb).to eq("POST")
        expect(request.path).to eq("/v1/customer/disputes/PP-R-HDH-1/provide-supporting-info")
        expect(request.headers["Paypal-Auth-Assertion"]).to eq(assertion)

        encoded_request = OpenStruct.new(verb: request.verb, path: request.path, body: request.body,
                                         headers: request.headers.transform_keys(&:downcase))
        encoded = PayPalHttp::Encoder.new.serialize_request(encoded_request)
        expect(encoded).to include('Content-Disposition: form-data; name="input"; filename="input.json"')
        expect(encoded).to include({ notes: "Downloaded at 19:35:53 UTC" }.to_json)
        expect(encoded_request.headers["content-type"]).to start_with("multipart/form-data; boundary=")
        OpenStruct.new(status_code: 200, result: OpenStruct.new)
      end

      api_object.provide_dispute_supporting_info(dispute_id: "PP-R-HDH-1", merchant_account:, notes: "Downloaded at 19:35:53 UTC")
    end
  end
end
