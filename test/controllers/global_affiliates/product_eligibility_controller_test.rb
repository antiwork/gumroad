# frozen_string_literal: true

require "test_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

class GlobalAffiliatesProductEligibilityControllerTest < ActionController::TestCase
  self.described_class = GlobalAffiliates::ProductEligibilityController
  tests GlobalAffiliates::ProductEligibilityController



  context_ GlobalAffiliates::ProductEligibilityController do
    it_behaves_like "inherits from Sellers::BaseController"

    let(:seller) { create(:named_seller) }

    include_context "with user signed in as admin for seller"

  context_ "GET show" do
      it_behaves_like "authorize called for action", :get, :show do
        let(:record) { :affiliated }
        let(:policy_klass) { Products::AffiliatedPolicy }
        let(:policy_method) { :index? }
        let(:request_params) { { url: "https://example.com" } }
      end

  context_ "with invalid URL" do
        let(:url) { "https://example.com" }

  test "returns an error" do
          get :show, format: :json, params: { url: }

          expect(response).to be_successful
          expect(response.parsed_body["success"]).to be(false)
          expect(response.parsed_body["error"]).to eq("Please provide a valid Gumroad product URL")
        end
      end

  context_ "with non-ASCII characters in URL" do
        let(:url) { "https://gumroad.com/discover.json?a=123\u201D" }

  test "returns an error instead of raising URI::InvalidURIError" do
          get :show, format: :json, params: { url: }

          expect(response).to be_successful
          expect(response.parsed_body["success"]).to be(false)
          expect(response.parsed_body["error"]).to eq("Please provide a valid Gumroad product URL")
        end
      end
    end
  end
end
