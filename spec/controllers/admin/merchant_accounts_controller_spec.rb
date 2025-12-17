# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"
require "inertia_rails/rspec"

describe Admin::MerchantAccountsController, type: :controller, inertia: true do
  render_views

  it_behaves_like "inherits from Admin::BaseController"

  let(:admin_user) { create(:admin_user) }

  before do
    sign_in admin_user
  end

  describe "GET show" do
    let(:merchant_account) { create(:merchant_account) }

    before do
      allow(Stripe::Account).to receive(:retrieve).and_return(double(:account, charges_enabled: true, payouts_enabled: true, requirements: double(:requirements, disabled_reason: nil, as_json: {})))
    end

    it "redirects numeric ID to external_id" do
      get :show, params: { external_id: merchant_account.id }
      expect(response).to redirect_to admin_merchant_account_path(merchant_account.external_id)
    end

    it "renders the page successfully with external_id" do
      get :show, params: { external_id: merchant_account.external_id }

      expect(response).to be_successful
      expect(inertia.component).to eq("Admin/MerchantAccounts/Show")
    end

    it "renders the page successfully with charge_processor_merchant_id" do
      get :show, params: { external_id: merchant_account.charge_processor_merchant_id }

      expect(response).to be_successful
      expect(inertia.component).to eq("Admin/MerchantAccounts/Show")
    end
  end
end
