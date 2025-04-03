# frozen_string_literal: true

require "spec_helper"

describe Iffy::Product::IngestService do
  include SignedUrlHelper
  include Rails.application.routes.url_helpers

  let(:user) { create(:user) }
  let!(:merchant_account) { create(:merchant_account, user: user) }
  let(:product) { create(:product, user:, name: "Test Product", description: "A test product description.") }
  let(:service) { described_class.new(product) }

  describe "#perform" do
    context "when the API request is successful" do
      let(:successful_parsed_response) { { "status" => "success", "message" => "Content ingested successfully" } }
      let(:successful_response) { instance_double(HTTParty::Response, code: 200, parsed_response: successful_parsed_response, success?: true) }

      before do
        allow(HTTParty).to receive(:post).and_return(successful_response)
      end

      it "sends the correct data to the Iffy API and returns the response" do
        expect(HTTParty).to receive(:post).with(
          Iffy::Product::IngestService::URL,
          {
            body: {
              clientId: product.external_id,
              clientUrl: product.long_url,
              name: product.name,
              entity: "Product",
              text: "Name: Test Product Description: A test product description. ",
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
        expect { service.perform }.to raise_error("Iffy error for product ID #{product.id}: 400 - API error")
      end
    end

    context "with rich content and images" do
      let(:gif_preview) { create(:asset_preview_gif, link: product) }
      let(:jpg_preview) { create(:asset_preview_jpg, link: product) }
      let(:image_file) { create(:product_file, link: product, filegroup: "image") }
      let(:rich_content) do
        create(:rich_content, entity: product, description: [
                 { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Rich content text" }] }
               ])
      end

      before do
        gif_preview
        jpg_preview
        image_file
        rich_content
        allow(service).to receive(:signed_download_url_for_s3_key_and_filename).and_return("https://example.com/image.jpg")
        allow(URI).to receive(:open).and_return(double(content_type: "image/jpeg", read: "image_data"))
        allow(HTTParty).to receive(:post).and_return(instance_double(HTTParty::Response, code: 200, parsed_response: { "status" => "success" }, success?: true))
      end

      it "includes rich content text and image URLs in the API request" do
        expect(HTTParty).to receive(:post).with(
          Iffy::Product::IngestService::URL,
          hash_including(
            body: {
              clientId: product.external_id,
              clientUrl: product.long_url,
              name: product.name,
              entity: "Product",
              text: "Name: #{product.name} Description: #{product.description} Rich content text",
              fileUrls: [
                gif_preview.url,
                jpg_preview.url
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
