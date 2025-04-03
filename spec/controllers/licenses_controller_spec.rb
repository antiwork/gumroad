# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe LicensesController do
  it_behaves_like "inherits from Sellers::BaseController"

  render_views

  let(:seller) { create(:named_seller) }
  let(:license) { create(:license) }

  include_context "with user signed in as admin for seller"

  it_behaves_like "authorize called for controller", Audience::PurchasePolicy do
    let(:record) { license.purchase }
    let(:policy_method) { :manage_license? }
    let(:request_params) { { id: license.external_id } }
  end

  describe "PUT update" do
    it "updates the enabled status of the license" do
      expect(license.disabled_at).to be_nil
      put :update, format: :json, params: { id: license.external_id, enabled: false }
      expect(response).to be_successful
      expect(license.reload.disabled_at).to_not be_nil

      put :update, format: :json, params: { id: license.external_id, enabled: true }
      expect(response).to be_successful
      expect(license.reload.disabled_at).to be_nil
    end
  end
end
