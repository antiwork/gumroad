# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe CustomDomain::VerificationsController do
  it_behaves_like "inherits from Sellers::BaseController"

  describe "POST create" do
    let(:seller) { create(:named_seller) }

    include_context "with user signed in as admin for seller"

    it_behaves_like "authorize called for action", :post, :create do
      let(:record) { seller }
      let(:policy_klass) { Settings::Advanced::UserPolicy }
      let(:policy_method) { :show? }
    end

    context "when a blank domain is specified" do
      it "returns error response" do
        post :create, format: :json, params: { domain: "" }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["success"]).to eq(false)
      end
    end

    context "when the specified domain is correctly configured" do
      let(:domain) { "product.example.com" }

      before do
        allow_any_instance_of(Resolv::DNS)
          .to receive(:getresources)
          .with(domain, Resolv::DNS::Resource::IN::CNAME)
          .and_return([double(name: CUSTOM_DOMAIN_CNAME)])
      end

      it "returns success response" do
        post :create, params: { domain: }, as: :json

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["success"]).to eq(true)
        expect(response.parsed_body["message"]).to eq("product.example.com domain is correctly configured!")
      end

      context "when the specified domain is for a product" do
        let(:product) { create(:product) }

        it "returns a success response" do
          post :create, params: { domain:, product_id: product.external_id }, as: :json

          expect(response).to have_http_status(:ok)
          expect(response.parsed_body["success"]).to eq(true)
          expect(response.parsed_body["message"]).to eq("product.example.com domain is correctly configured!")
        end

        context "when the product already has a custom domain" do
          let!(:custom_domain) { create(:custom_domain, domain: "domain.example.com", user: nil, product:) }

          it "verifies the new domain and returns a success response" do
            post :create, params: { domain:, product_id: product.external_id }, as: :json

            expect(response).to have_http_status(:ok)
            expect(response.parsed_body["success"]).to eq(true)
            expect(response.parsed_body["message"]).to eq("product.example.com domain is correctly configured!")
          end
        end

        context "when the specified domain matches another product's custom domain" do
          let(:another_product) { create(:product) }
          let!(:custom_domain) { create(:custom_domain, domain: "product.example.com", user: nil, product: another_product) }

          it "returns error response with message" do
            post :create, params: { domain:, product_id: product.external_id }, as: :json

            expect(response).to have_http_status(:ok)
            expect(response.parsed_body["success"]).to eq(false)
            expect(response.parsed_body["message"]).to eq("The custom domain is already in use.")
          end
        end
      end
    end

    context "when the specified domain is not configured" do
      let(:domain) { "store.example.com" }

      before do
        allow_any_instance_of(Resolv::DNS)
          .to receive(:getresources)
          .with(domain, anything)
          .and_return([])
        allow_any_instance_of(Resolv::DNS)
          .to receive(:getresources)
          .with(CUSTOM_DOMAIN_CNAME, anything)
          .and_return([double(address: "100.0.0.1")])
        allow_any_instance_of(Resolv::DNS)
          .to receive(:getresources)
          .with(CUSTOM_DOMAIN_STATIC_IP_HOST, Resolv::DNS::Resource::IN::A)
          .and_return([double(address: "100.0.0.2")])
      end

      it "returns success response" do
        post :create, format: :json, params: { domain: }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq("Domain verification failed. Please make sure you have correctly configured the DNS record for store.example.com.")
      end
    end
  end
end
