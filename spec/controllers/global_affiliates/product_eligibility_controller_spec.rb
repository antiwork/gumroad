# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe GlobalAffiliates::ProductEligibilityController do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }

  include_context "with user signed in as admin for seller"

  describe "GET show" do
    it_behaves_like "authorize called for action", :get, :show do
      let(:record) { :affiliated }
      let(:policy_klass) { Products::AffiliatedPolicy }
      let(:policy_method) { :index? }
      let(:request_params) { { url: "https://example.com" } }
    end

    context "with a valid Gumroad product URL" do
      let(:product) { create(:product, name: "Eligible Product") }
      let(:url) { product.long_url }

      before do
        # The controller fetches the product's own public JSON endpoint to
        # resolve the URL (handling short/subdomain/custom-permalink routing),
        # then reads eligibility fields from the model. Stub the HTTP round-trip
        # so the spec doesn't depend on a live request to the app under test.
        stub_request(:get, "#{url}.json")
          .to_return(status: 200, body: { api_version: ProductPresenter::PublicApiProps::API_VERSION, id: product.external_id, permalink: product.general_permalink }.to_json, headers: { "Content-Type" => "application/json" })
      end

      it "returns the eligibility fields for the resolved product" do
        get :show, format: :json, params: { url: }

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(true)
        expect(response.parsed_body["product"]).to eq(
          "name" => product.name,
          "formatted_price" => product.price_formatted_verbose,
          "recommendable" => product.recommendable?,
          "short_url" => product.long_url,
        )
      end
    end

    context "with a valid Gumroad product URL using a custom permalink" do
      let(:product) { create(:product, name: "Eligible Product", custom_permalink: "custom-product") }
      let(:url) { product.long_url }

      before do
        stub_request(:get, "#{url}.json")
          .to_return(status: 200, body: { api_version: ProductPresenter::PublicApiProps::API_VERSION, id: product.external_id, permalink: product.custom_permalink }.to_json, headers: { "Content-Type" => "application/json" })
      end

      it "returns the eligibility fields for the resolved product" do
        get :show, format: :json, params: { url: }

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(true)
        expect(response.parsed_body["product"]).to eq(
          "name" => product.name,
          "formatted_price" => product.price_formatted_verbose,
          "recommendable" => product.recommendable?,
          "short_url" => product.long_url,
        )
      end
    end

    context "when the resolved product id does not match a product" do
      let(:product) { create(:product) }
      let(:url) { product.long_url }

      before do
        stub_request(:get, "#{url}.json")
          .to_return(status: 200, body: { api_version: ProductPresenter::PublicApiProps::API_VERSION, id: "doesnotexist", permalink: product.general_permalink }.to_json, headers: { "Content-Type" => "application/json" })
      end

      it "returns an error" do
        get :show, format: :json, params: { url: }

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["error"]).to eq("Please provide a valid Gumroad product URL")
      end
    end

    context "when the URL resolves to non-product JSON" do
      let(:url) { "#{PROTOCOL}://#{DOMAIN}/some-seller" }

      before do
        stub_request(:get, "#{url}.json")
          .to_return(status: 200, body: { id: create(:user).external_id }.to_json, headers: { "Content-Type" => "application/json" })
      end

      it "returns an error" do
        get :show, format: :json, params: { url: }

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["error"]).to eq("Please provide a valid Gumroad product URL")
      end
    end

    context "with invalid URL" do
      let(:url) { "https://example.com" }

      it "returns an error" do
        get :show, format: :json, params: { url: }

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["error"]).to eq("Please provide a valid Gumroad product URL")
      end
    end

    context "with non-ASCII characters in URL" do
      let(:url) { "https://gumroad.com/discover.json?a=123\u201D" }

      it "returns an error instead of raising URI::InvalidURIError" do
        get :show, format: :json, params: { url: }

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["error"]).to eq("Please provide a valid Gumroad product URL")
      end
    end
  end
end
