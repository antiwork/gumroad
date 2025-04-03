# frozen_string_literal: true

require "spec_helper"

describe Iffy::Profile::IngestService do
  include Rails.application.routes.url_helpers

  let(:user) { create(:user, name: "Test User", bio: "A test user bio.") }
  let!(:merchant_account) { create(:merchant_account, user: user) }
  let(:service) { described_class.new(user) }

  before do
    stub_const("Iffy::Profile::IngestService::TEST_MODE", false)
  end

  describe "#perform" do
    context "when the API request is successful" do
      let(:successful_parsed_response) { { "status" => "success", "message" => "Content ingested successfully" } }
      let(:successful_response) { instance_double(HTTParty::Response, code: 200, parsed_response: successful_parsed_response, success?: true) }

      before do
        allow(HTTParty).to receive(:post).and_return(successful_response)
      end

      it "sends the correct data to the Iffy API and returns the response" do
        expect(HTTParty).to receive(:post).with(
          Iffy::Profile::IngestService::URL,
          {
            body: {
              clientId: user.external_id,
              clientUrl: user.profile_url,
              name: user.display_name,
              entity: "Profile",
              text: "Test User A test user bio. ",
              fileUrls: [],
              user: {
                clientId: user.external_id,
                protected: user.vip_creator?,
                email: user.email,
                username: user.username,
                stripeAccountId: user.stripe_account&.charge_processor_merchant_id
              }
            }.to_json,
            headers: {
              "Authorization" => "Bearer #{GlobalConfig.get("IFFY_API_KEY")}"
            }
          }
        )

        result = service.perform
        expect(result).to eq(successful_parsed_response)
      end
    end

    context "when the API request fails" do
      let(:error_parsed_response) { { "error" => { "message" => "API error" } } }
      let(:error_response) { instance_double(HTTParty::Response, code: 400, parsed_response: error_parsed_response, success?: false) }

      before do
        allow(HTTParty).to receive(:post).and_return(error_response)
      end

      it "raises an error with the appropriate message" do
        expect { service.perform }.to raise_error("Iffy error for user ID #{user.id}: 400 - API error")
      end
    end

    context "with rich text sections and images" do
      before do
        create(:seller_profile_rich_text_section, seller: user, json_data: {
                 text: {
                   content: [
                     { type: "paragraph", content: [{ text: "Rich content text" }] },
                     { type: "image", attrs: { src: "https://example.com/image1.jpg" } },
                     { type: "image", attrs: { src: "https://example.com/image2.jpg" } }
                   ]
                 }
               })
        allow(HTTParty).to receive(:post).and_return(instance_double(HTTParty::Response, code: 200, parsed_response: { "status" => "success" }, success?: true))
      end

      it "includes rich content text and image URLs in the API request" do
        expect(HTTParty).to receive(:post).with(
          Iffy::Profile::IngestService::URL,
          hash_including(
            body: {
              clientId: user.external_id,
              clientUrl: user.profile_url,
              name: user.display_name,
              entity: "Profile",
              text: "Test User A test user bio. Rich content text",
              fileUrls: [
                "https://example.com/image1.jpg",
                "https://example.com/image2.jpg"
              ],
              user: {
                clientId: user.external_id,
                protected: user.vip_creator?,
                email: user.email,
                username: user.username,
                stripeAccountId: user.stripe_account&.charge_processor_merchant_id
              }
            }.to_json,
            headers: {
              "Authorization" => "Bearer #{GlobalConfig.get("IFFY_API_KEY")}"
            }
          )
        )

        service.perform
      end
    end
  end
end
