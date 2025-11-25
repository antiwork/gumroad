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
    let(:merchant_account) { MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) }

    it "renders the page successfully" do
      get :show, params: { id: merchant_account }

      expect(response).to be_successful
      expect(inertia.component).to eq("Admin/MerchantAccounts/Show")
    end
  end
end
