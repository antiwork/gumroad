# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Checkout::Upsells::PausesController do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller, :eligible_for_service_products) }
  let(:unpaused_upsell) { create(:upsell, seller:, paused: false) }
  let(:paused_upsell) { create(:upsell, seller:, paused: true) }

  before { sign_in seller }

  describe "POST create" do
    it_behaves_like "authorize called for action", :post, :create do
      let(:policy_klass) { Checkout::UpsellPolicy }
      let(:policy_method) { :pause? }
      let(:record) { unpaused_upsell }
      let(:request_params) { { upsell_id: unpaused_upsell.external_id } }
      let(:request_format) { :json }
    end

    it "pauses the upsell" do
      expect { post :create, params: { upsell_id: unpaused_upsell.external_id }, as: :json }
        .to change { unpaused_upsell.reload.paused }.from(false).to(true)

      expect(response).to have_http_status(:no_content)
    end

    context "when upsell doesn't exist" do
      it "returns a 404 error" do
        expect { post :create, params: { upsell_id: "nonexistent" }, as: :json }
          .to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end

  describe "DELETE destroy" do
    it_behaves_like "authorize called for action", :delete, :destroy do
      let(:policy_klass) { Checkout::UpsellPolicy }
      let(:policy_method) { :unpause? }
      let(:record) { paused_upsell }
      let(:request_params) { { upsell_id: paused_upsell.external_id } }
      let(:request_format) { :json }
    end

    it "unpauses the upsell" do
      expect { delete :destroy, params: { upsell_id: paused_upsell.external_id }, as: :json }
        .to change { paused_upsell.reload.paused }.from(true).to(false)

      expect(response).to have_http_status(:no_content)
    end

    context "when upsell doesn't exist" do
      it "returns a 404 error" do
        expect { delete :destroy, params: { upsell_id: "nonexistent" }, as: :json }
          .to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end
end
