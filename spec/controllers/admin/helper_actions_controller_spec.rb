# frozen_string_literal: true

RSpec.describe Admin::HelperActionsController do
  let(:admin) { create(:admin_user) }
  let(:user) { create(:user) }

  describe "GET impersonate" do
    it "redirects to admin impersonation when authenticated as admin" do
      sign_in(admin)

      get :impersonate, params: { user_external_id: user.external_id }

      expect(response).to redirect_to(admin_impersonate_path(user_identifier: user.external_id))
    end

    it "redirects to root path when not authenticated as admin" do
      sign_in(create(:user))

      get :impersonate, params: { user_external_id: user.external_id }

      expect(response).to redirect_to(root_path)
    end

    it "returns not found for invalid user" do
      sign_in(admin)

      get :impersonate, params: { user_external_id: "invalid" }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET stripe_dashboard" do
    let(:merchant_account) { create(:merchant_account, charge_processor_id: StripeChargeProcessor.charge_processor_id) }
    let(:user_with_stripe) { merchant_account.user }

    it "redirects to Stripe dashboard when authenticated as admin" do
      sign_in(admin)

      get :stripe_dashboard, params: { user_external_id: user_with_stripe.external_id }

      expect(response).to redirect_to("https://dashboard.stripe.com/connect/accounts/#{merchant_account.charge_processor_merchant_id}")
    end

    it "redirects to root path when not authenticated as admin" do
      sign_in(create(:user))

      get :stripe_dashboard, params: { user_external_id: user_with_stripe.external_id }

      expect(response).to redirect_to(root_path)
    end

    it "returns not found when user has no Stripe account" do
      sign_in(admin)

      get :stripe_dashboard, params: { user_external_id: user.external_id }

      expect(response).to have_http_status(:not_found)
    end

    it "returns not found for invalid user" do
      sign_in(admin)

      get :stripe_dashboard, params: { user_external_id: "invalid" }

      expect(response).to have_http_status(:not_found)
    end
  end
end
