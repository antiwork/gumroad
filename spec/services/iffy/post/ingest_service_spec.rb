# frozen_string_literal: true

require "spec_helper"

describe Iffy::Post::IngestService do
  let(:user) { create(:user) }
  let!(:merchant_account) { create(:merchant_account, user: user) }
  let(:installment) { create(:installment, seller: user, name: "Test Post", message: "<p>A test post message.</p>") }
  let(:service) { described_class.new(installment) }

  describe "#perform" do
    context "when the API request is successful" do
      let(:successful_parsed_response) { { "status" => "success", "message" => "Content ingested successfully" } }
      let(:successful_response) { instance_double(HTTParty::Response, code: 200, parsed_response: successful_parsed_response, success?: true) }

      before do
        allow(HTTParty).to receive(:post).and_return(successful_response)
      end

      it "sends the correct data to the Iffy API and returns the response" do
        expect(HTTParty).to receive(:post).with(
          Iffy::Post::IngestService::URL,
          {
            body: {
              clientId: installment.external_id,
              clientUrl: installment.full_url,
              name: installment.name,
              entity: "Post",
              text: "Name: Test Post Message: A test post message.",
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
        expect { service.perform }.to raise_error("Iffy error for installment ID #{installment.id}: 400 - API error")
      end
    end

    context "with rich content and images" do
      let(:message_with_images) { "<p>Rich content text</p><img src='https://example.com/image1.jpg'><img src='https://example.com/image2.jpg'>" }
      let(:installment_with_images) { create(:installment, seller: user, name: "Test Post with Images", message: message_with_images) }
      let(:service_with_images) { described_class.new(installment_with_images) }

      before do
        allow(HTTParty).to receive(:post).and_return(instance_double(HTTParty::Response, code: 200, parsed_response: { "status" => "success" }, success?: true))
      end

      it "includes rich content text and image URLs in the API request" do
        expect(HTTParty).to receive(:post).with(
          Iffy::Post::IngestService::URL,
          hash_including(
            body: {
              clientId: installment_with_images.external_id,
              clientUrl: installment_with_images.full_url,
              name: installment_with_images.name,
              entity: "Post",
              text: "Name: Test Post with Images Message: Rich content text",
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

        service_with_images.perform
      end
    end
  end
end
