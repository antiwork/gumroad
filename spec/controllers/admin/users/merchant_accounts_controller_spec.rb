# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"

describe Admin::Users::MerchantAccountsController do
  it_behaves_like "inherits from Admin::BaseController"

  let(:admin_user) { create(:admin_user) }
  let(:user) { create(:user) }

  before do
    sign_in admin_user
  end

  describe "GET 'index'" do
    context "when user has no merchant accounts" do
      it "returns empty merchant accounts and false for stripe account" do
        get :index, params: { user_id: user.id }, format: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body["merchant_accounts"]).to eq([])
        expect(response.parsed_body["has_stripe_account"]).to eq(false)
      end
    end

    context "when user has live merchant accounts" do
      let!(:paypal_account) { create(:merchant_account_paypal, user: user) }
      let!(:stripe_account) { create(:merchant_account, user: user) }

      it "returns merchant accounts with expected fields" do
        get :index, params: { user_id: user.id }, format: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body["merchant_accounts"].length).to eq(2)

        merchant_account = response.parsed_body["merchant_accounts"].first
        expect(merchant_account.keys).to match_array(%w[id charge_processor_id alive charge_processor_alive])
      end

      it "returns true for has_stripe_account" do
        get :index, params: { user_id: user.id }, format: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body["has_stripe_account"]).to eq(true)
      end
    end

    context "when user has deleted or inactive merchant accounts" do
      let!(:deleted_account) do
        create(:merchant_account, user: user).tap do |ma|
          ma.update!(charge_processor_deleted_at: Time.current)
        end
      end
      let!(:inactive_account) do
        create(:merchant_account, user: user).tap do |ma|
          ma.mark_deleted!
        end
      end

      it "returns false for has_stripe_account" do
        get :index, params: { user_id: user.id }, format: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body["has_stripe_account"]).to eq(false)
      end
    end

    context "when user has only paypal accounts" do
      let!(:paypal_account) { create(:merchant_account_paypal, user: user) }

      it "returns false for has_stripe_account" do
        get :index, params: { user_id: user.id }, format: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body["has_stripe_account"]).to eq(false)
      end
    end
  end
end
