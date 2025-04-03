# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe CallsController do
  let(:seller) { create(:named_seller, :eligible_for_service_products) }
  let(:pundit_user) { SellerContext.new(user: seller, seller:) }
  let(:product) { create(:call_product, :available_for_a_year, user: seller) }
  let(:purchase) { create(:call_purchase, seller:, link: product) }
  let(:call) { purchase.call }

  include_context "with user signed in as admin for seller"

  describe "PUT update" do
    it_behaves_like "authorize called for action", :put, :update do
      let(:policy_klass) { CallPolicy }
      let(:record) { call }
      let(:request_params) { { id: call.external_id } }
    end

    context "when the update is successful" do
      it "updates the call and returns no content" do
        expect do
          put :update, params: { id: call.external_id, call_url: "https://zoom.us/j/thing" }, as: :json
        end.to change { call.reload.call_url }.to eq("https://zoom.us/j/thing")

        expect(response).to be_successful
        expect(response).to have_http_status(:no_content)
      end
    end

    context "when the call doesn't exist" do
      it "returns a 404 error" do
        expect { put :update, params: { id: "non_existent_id" } }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end
end
