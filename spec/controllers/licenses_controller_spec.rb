# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe LicensesController do
  it_behaves_like "inherits from Sellers::BaseController"

  render_views

  let(:seller) { create(:named_seller) }
  let(:license) { create(:license) }
  let(:secure_id) { license.secure_external_id(scope: License::MANAGE_SECURE_ID_SCOPE) }

  include_context "with user signed in as admin for seller"

  it_behaves_like "authorize called for controller", Audience::PurchasePolicy do
    let(:record) { license.purchase }
    let(:policy_method) { :manage_license? }
    let(:request_params) { { id: secure_id } }
  end

  describe "PUT update" do
    it "updates the enabled status of the license" do
      expect(license.disabled_at).to be_nil
      put :update, format: :json, params: { id: secure_id, enabled: false }
      expect(response).to be_successful
      expect(license.reload.disabled_at).to_not be_nil

      put :update, format: :json, params: { id: secure_id, enabled: true }
      expect(response).to be_successful
      expect(license.reload.disabled_at).to be_nil
    end

    it "resets the license uses when reset_uses is passed" do
      license.update!(uses: 7)
      put :update, format: :json, params: { id: secure_id, reset_uses: true }
      expect(response).to be_successful
      expect(license.reload.uses).to eq 0
    end

    it "does not change the enabled status when resetting uses" do
      license.update!(uses: 3)
      expect(license.disabled_at).to be_nil
      put :update, format: :json, params: { id: secure_id, reset_uses: true }
      expect(response).to be_successful
      expect(license.reload.disabled_at).to be_nil
      expect(license.uses).to eq 0
    end

    context "when the id is not a valid management token" do
      before { license.update!(uses: 9) }

      it "rejects the plain external id that leaks via the license API" do
        put :update, format: :json, params: { id: license.external_id, reset_uses: true }
        expect(response).to have_http_status(:not_found)
        expect(license.reload.uses).to eq 9
      end

      it "rejects a token minted for a different scope" do
        wrong_scope_id = license.secure_external_id(scope: "some_other_scope")
        put :update, format: :json, params: { id: wrong_scope_id, enabled: false }
        expect(response).to have_http_status(:not_found)
        expect(license.reload.disabled_at).to be_nil
      end

      it "rejects a forged token" do
        put :update, format: :json, params: { id: "not-a-real-token", reset_uses: true }
        expect(response).to have_http_status(:not_found)
        expect(license.reload.uses).to eq 9
      end
    end
  end
end
