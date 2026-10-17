# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe GlobalAffiliates::ProductEligibilityController do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }

  include_context "with user signed in as admin for seller"

  describe "GET show", skip_ssrf_stub: true do
    let(:public_address) { "93.184.216.34" }

    before do
      # Real SsrfFilter, controlled DNS: WebMock serves the response, the filter decides where to connect.
      allow(Resolv).to receive(:getaddresses).and_return([public_address])
    end

    def product_json_response(product)
      { status: 200, body: { api_version: ProductPresenter::PublicApiProps::API_VERSION, id: product.external_id, permalink: product.general_permalink }.to_json, headers: { "Content-Type" => "application/json" } }
    end

    def expect_invalid_url_error
      expect(response).to be_successful
      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["error"]).to eq("Please provide a valid Gumroad product URL")
    end

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
        expect(SsrfFilter).not_to receive(:get)

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
      let(:off_site_url) { "https://example.com/l/redirected.json" }

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
        expect(Resolv).not_to have_received(:getaddresses).with("example.com")
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
        expect(SsrfFilter).not_to receive(:get)

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

    context "with credentials, no path, or no scheme" do
      ["#{PROTOCOL}://user:secret@#{DOMAIN}/l/product", "#{PROTOCOL}://#{DOMAIN}", "//#{DOMAIN}/l/product"].each do |rejected_url|
        it "returns an error without fetching #{rejected_url}" do
          expect(SsrfFilter).not_to receive(:get)

          get :show, format: :json, params: { url: rejected_url }

          expect_invalid_url_error
        end
      end
    end

    context "when the host resolves only to private or reserved addresses" do
      let(:url) { "#{PROTOCOL}://#{DOMAIN}/l/internal" }

      before do
        allow(Resolv).to receive(:getaddresses).and_return(["127.0.0.1", "169.254.169.254", "10.0.0.5"])
        stub_request(:get, "#{url}.json").to_return(product_json_response(create(:product)))
      end

      it "returns an error without connecting" do
        get :show, format: :json, params: { url: }

        expect_invalid_url_error
        expect(a_request(:get, "#{url}.json")).not_to have_been_made
      end
    end

    context "when the host does not resolve" do
      let(:url) { "#{PROTOCOL}://#{DOMAIN}/l/unresolved" }

      before { allow(Resolv).to receive(:getaddresses).and_return([]) }

      it "returns an error" do
        get :show, format: :json, params: { url: }

        expect_invalid_url_error
      end
    end

    context "when a redirect lands on one of our hosts that resolves privately" do
      let(:product) { create(:product) }
      let(:url) { "#{PROTOCOL}://#{DOMAIN}/l/#{product.general_permalink}" }
      let(:redirect_url) { "#{product.long_url}.json" }

      before do
        allow(Resolv).to receive(:getaddresses).with(URI(redirect_url).hostname).and_return(["10.0.0.5"])
        stub_request(:get, "#{url}.json").to_return(status: 301, headers: { "Location" => redirect_url })
        stub_request(:get, redirect_url).to_return(product_json_response(product))
      end

      it "returns an error without connecting to that hop" do
        get :show, format: :json, params: { url: }

        expect_invalid_url_error
        expect(a_request(:get, redirect_url)).not_to have_been_made
      end
    end

    context "when DNS mixes private and public answers, then changes" do
      let(:product) { create(:product) }
      let(:url) { product.long_url }
      let(:uri) { URI(url) }

      before do
        allow(Resolv).to receive(:getaddresses).and_return(["10.0.0.5", public_address], ["127.0.0.1"])
        allow(Net::HTTP).to receive(:start).and_call_original
        stub_request(:get, "#{url}.json").to_return(product_json_response(product))
      end

      it "connects to the public address it checked, without a second lookup" do
        get :show, format: :json, params: { url: }

        expect(response.parsed_body["success"]).to be(true)
        expect(Resolv).to have_received(:getaddresses).once
        expect(Net::HTTP).to have_received(:start).with(uri.hostname, uri.port, hash_including(ipaddr: public_address)).once
      end
    end

    context "when a short-domain URL redirects to the seller subdomain" do
      let(:product) { create(:product, custom_permalink: "custom-product") }
      let(:url) { "#{PROTOCOL}://#{SHORT_DOMAIN}/custom-product" }

      before do
        stub_request(:get, "#{url}.json").to_return(status: 301, headers: { "Location" => "#{product.long_url}.json" })
        stub_request(:get, "#{product.long_url}.json").to_return(product_json_response(product))
      end

      it "returns the eligibility fields" do
        get :show, format: :json, params: { url: }

        expect(response.parsed_body["success"]).to be(true)
        expect(response.parsed_body["product"]["short_url"]).to eq(product.long_url)
      end
    end

    context "when relative redirects exceed the budget by one" do
      let(:hop_url) { "#{PROTOCOL}://#{DOMAIN}/l/hop" }
      let(:last_hop) { described_class::MAX_REDIRECTS + 1 }

      before do
        last_hop.times { |hop| stub_request(:get, "#{hop_url}#{hop}.json").to_return(status: 302, headers: { "Location" => "hop#{hop + 1}.json" }) }
        stub_request(:get, "#{hop_url}#{last_hop}.json").to_return(product_json_response(create(:product)))
      end

      it "returns an error without requesting the extra hop" do
        get :show, format: :json, params: { url: "#{hop_url}0" }

        expect_invalid_url_error
        expect(a_request(:get, "#{hop_url}#{last_hop}.json")).not_to have_been_made
      end
    end

    context "when the response is JSON but not an object" do
      let(:url) { "#{PROTOCOL}://#{DOMAIN}/l/array" }

      before do
        stub_request(:get, "#{url}.json").to_return(status: 200, body: [{ api_version: ProductPresenter::PublicApiProps::API_VERSION }].to_json, headers: { "Content-Type" => "application/json" })
      end

      it "returns an error" do
        get :show, format: :json, params: { url: }

        expect_invalid_url_error
      end
    end

    [OpenSSL::SSL::SSLError, Net::OpenTimeout, Errno::ETIMEDOUT].each do |error_class|
      context "when the fetch raises #{error_class}" do
        let(:url) { "#{PROTOCOL}://#{DOMAIN}/l/failing" }

        before { stub_request(:get, "#{url}.json").to_raise(error_class) }

        it "returns an error instead of raising" do
          get :show, format: :json, params: { url: }

          expect_invalid_url_error
        end
      end
    end

    context "in development, with the app's own localhost URLs" do
      let(:product_seller) { create(:user, username: "productseller") }

      before do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
        stub_const("ROOT_DOMAIN", "localhost:3000")
        stub_const("DOMAIN", "localhost:3000")
        stub_const("SHORT_DOMAIN", "s.localhost:3000")
        allow(SsrfFilter).to receive(:get).and_call_original
      end

      it "resolves a seller-subdomain custom permalink to that seller's product without fetching" do
        create(:product, user: create(:user, username: "otherseller"), custom_permalink: "shared")
        product = create(:product, user: product_seller, custom_permalink: "shared")

        get :show, format: :json, params: { url: "http://productseller.localhost:3000/l/shared" }

        expect(response.parsed_body["success"]).to be(true)
        expect(response.parsed_body["product"]).to include("name" => product.name, "short_url" => "http://productseller.localhost:3000/l/shared")
        expect(SsrfFilter).not_to have_received(:get)
        expect(Resolv).not_to have_received(:getaddresses)
      end

      it "resolves a short-domain URL without fetching" do
        product = create(:product, user: product_seller)

        get :show, format: :json, params: { url: "http://s.localhost:3000/#{product.unique_permalink}" }

        expect(response.parsed_body["product"]["name"]).to eq(product.name)
        expect(SsrfFilter).not_to have_received(:get)
      end

      it "resolves a root-domain /l/ URL without fetching" do
        product = create(:product, user: product_seller)

        get :show, format: :json, params: { url: "http://localhost:3000/l/#{product.unique_permalink}" }

        expect(response.parsed_body["product"]["name"]).to eq(product.name)
        expect(SsrfFilter).not_to have_received(:get)
      end

      it "resolves a product URL that carries an offer code" do
        product = create(:product, user: product_seller, custom_permalink: "shared")

        get :show, format: :json, params: { url: "http://productseller.localhost:3000/l/shared/SAVE10" }

        expect(response.parsed_body["product"]["name"]).to eq(product.name)
        expect(SsrfFilter).not_to have_received(:get)
      end

      it "refuses a banned product, like the product page" do
        create(:product, user: product_seller, custom_permalink: "shared").update_columns(banned_at: Time.current)

        get :show, format: :json, params: { url: "http://productseller.localhost:3000/l/shared" }

        expect_invalid_url_error
        expect(SsrfFilter).not_to have_received(:get)
      end

      it "refuses a product whose seller is deleted, like the product page" do
        product = create(:product, user: product_seller)
        product_seller.update_columns(deleted_at: Time.current)

        get :show, format: :json, params: { url: "http://localhost:3000/l/#{product.unique_permalink}" }

        expect_invalid_url_error
        expect(SsrfFilter).not_to have_received(:get)
      end

      ["http://localhost:3000/settings", "http://localhost:3000/l/missing", "http://nosuchseller.localhost:3000/l/shared"].each do |local_url|
        it "returns an error for #{local_url} without fetching" do
          get :show, format: :json, params: { url: local_url }

          expect_invalid_url_error
          expect(SsrfFilter).not_to have_received(:get)
        end
      end

      it "does not resolve a URL on another port locally" do
        expect(Link).not_to receive(:fetch_leniently)

        get :show, format: :json, params: { url: "http://productseller.localhost:4000/l/shared" }

        expect_invalid_url_error
      end
    end

    %w[production test].each do |environment|
      context "in #{environment}, with a URL on our configured origin that resolves to loopback" do
        let(:product) { create(:product, user: create(:user, username: "loopbackseller")) }

        before do
          allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new(environment))
          allow(Resolv).to receive(:getaddresses).and_return(["127.0.0.1"])
          stub_request(:get, "#{product.long_url}.json").to_return(product_json_response(product))
        end

        it "refuses it instead of resolving it locally" do
          expect(Link).not_to receive(:fetch_leniently)

          get :show, format: :json, params: { url: product.long_url }

          expect_invalid_url_error
          expect(Resolv).to have_received(:getaddresses).with(URI(product.long_url).hostname)
          expect(a_request(:get, "#{product.long_url}.json")).not_to have_been_made
        end
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
