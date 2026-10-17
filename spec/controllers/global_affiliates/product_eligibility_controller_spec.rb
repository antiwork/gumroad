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

    context "when the URL names a port our domains do not serve" do
      let(:url) { "#{PROTOCOL}://#{DOMAIN.sub(/:\d+\z/, "")}:9000/zzprobe" }

      it "returns an error without opening a connection" do
        expect(HTTParty).not_to receive(:get)

        get :show, format: :json, params: { url: }

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["error"]).to eq("Please provide a valid Gumroad product URL")
      end
    end

    context "when the Gumroad host refuses the connection" do
      let(:url) { "#{PROTOCOL}://#{DOMAIN}/l/refused" }

      before do
        stub_request(:get, "#{url}.json").to_raise(Errno::ECONNREFUSED)
      end

      it "returns an error instead of raising" do
        get :show, format: :json, params: { url: }

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["error"]).to eq("Please provide a valid Gumroad product URL")
      end
    end

    context "with an unparseable response body" do
      let(:url) { "#{PROTOCOL}://#{DOMAIN}/l/not-json" }

      before do
        stub_request(:get, "#{url}.json")
          .to_return(status: 200, body: "<html>not json</html>", headers: { "Content-Type" => "application/json" })
      end

      it "returns an error instead of raising" do
        get :show, format: :json, params: { url: }

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["error"]).to eq("Please provide a valid Gumroad product URL")
      end
    end

    context "when the Gumroad URL redirects to a host we do not serve" do
      let(:url) { "#{PROTOCOL}://#{DOMAIN}/l/redirected" }
      let(:off_site_url) { "http://192.0.2.1/l/redirected.json" }

      before do
        stub_request(:get, "#{url}.json").to_return(status: 302, headers: { "Location" => off_site_url })
        # The off-site host answers with product JSON the parser would accept, so the guard has to be
        # what refuses the hop.
        stub_request(:get, off_site_url)
          .to_return(status: 200, body: { api_version: ProductPresenter::PublicApiProps::API_VERSION, id: create(:product).external_id, permalink: "redirected" }.to_json, headers: { "Content-Type" => "application/json" })
      end

      it "returns an error without requesting the off-site host" do
        get :show, format: :json, params: { url: }

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["error"]).to eq("Please provide a valid Gumroad product URL")
        expect(a_request(:get, off_site_url)).not_to have_been_made
      end
    end

    context "when the Gumroad URL redirects to another host we serve" do
      let(:url) { "#{PROTOCOL}://#{DOMAIN}/l/redirected" }
      let(:redirect_url) { "#{PROTOCOL}://#{ROOT_DOMAIN}/l/redirected.json" }
      let(:product) { create(:product, name: "Eligible Product") }

      before do
        stub_request(:get, "#{url}.json").to_return(status: 301, headers: { "Location" => redirect_url })
        stub_request(:get, redirect_url)
          .to_return(status: 200, body: { api_version: ProductPresenter::PublicApiProps::API_VERSION, id: product.external_id, permalink: product.general_permalink }.to_json, headers: { "Content-Type" => "application/json" })
      end

      it "follows it and returns the eligibility fields" do
        get :show, format: :json, params: { url: }

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(true)
        expect(response.parsed_body["product"]["name"]).to eq(product.name)
      end
    end

    context "when the URL does not use http or https" do
      let(:url) { "ftp://#{DOMAIN}/l/product" }

      it "returns an error without opening a connection" do
        expect(HTTParty).not_to receive(:get)

        get :show, format: :json, params: { url: }

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["error"]).to eq("Please provide a valid Gumroad product URL")
      end
    end

    context "when the URL needs the full redirect budget" do
      let(:product) { create(:product) }
      let(:url) { "#{PROTOCOL}://#{DOMAIN}/l/hop0" }
      # MAX_REDIRECTS hops: hop0 -> hop1 -> ... -> the product JSON.
      let(:redirect_urls) { (1...described_class::MAX_REDIRECTS).map { |hop| "#{PROTOCOL}://#{DOMAIN}/l/hop#{hop}.json" } }
      let(:product_url) { "#{PROTOCOL}://#{DOMAIN}/l/product.json" }

      before do
        stub_request(:get, "#{url}.json").to_return(status: 302, headers: { "Location" => redirect_urls.first })
        redirect_urls.each_with_index do |redirect_url, index|
          stub_request(:get, redirect_url)
            .to_return(status: 302, headers: { "Location" => redirect_urls[index + 1] || product_url })
        end
        stub_request(:get, product_url)
          .to_return(status: 200, body: { api_version: ProductPresenter::PublicApiProps::API_VERSION, id: product.external_id, permalink: product.general_permalink }.to_json, headers: { "Content-Type" => "application/json" })
      end

      it "follows every hop and resolves the product" do
        get :show, format: :json, params: { url: }

        expect(response.parsed_body["success"]).to be(true)
        expect(response.parsed_body["product"]["name"]).to eq(product.name)
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
