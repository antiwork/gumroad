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

    context "with invalid URL" do
      let(:url) { "https://example.com" }

      it "returns an error" do
        get :show, format: :json, params: { url: }

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["error"]).to eq("Please provide a valid Gumroad product URL")
      end
    end
  end
end
