# frozen_string_literal: true

require "spec_helper"

describe OauthCompletionsController, :vcr do
  describe "#stripe" do
    let(:auth_uid) { "acct_1SOb0DEwFhlcVS6d" }
    let(:referer) { settings_payments_path }
    let(:user) { create(:user) }

    def set_session_data
      session[:stripe_connect_data] = {
        "auth_uid" => auth_uid,
        "referer" => referer,
        "signup" => false
      }
    end

    before do
      set_session_data
      sign_in user
    end

    context "when connecting a new Stripe account" do
      it "links to existing user account" do
        post :stripe

        expect(user.reload.stripe_connect_account).to be_present
        expect(user.stripe_connect_account.charge_processor_merchant_id).to eq(auth_uid)
        expect(flash[:notice]).to eq "You have successfully connected your Stripe account!"
        expect(response).to redirect_to settings_payments_url
      end

      it "redirects to dashboard when referer is not settings payments path" do
        session[:stripe_connect_data]["referer"] = dashboard_path

        post :stripe

        expect(response).to redirect_to dashboard_url
      end

      it "shows success message for new signups" do
        session[:stripe_connect_data]["signup"] = true

        post :stripe

        expect(flash[:notice]).to eq "You have successfully signed in with your Stripe account!"
      end

      it "allows connecting a Stripe account from Czechia" do
        session[:stripe_connect_data]["auth_uid"] = "acct_1SOk5nRHVSLfjXtK"

        post :stripe

        expect(user.reload.stripe_connect_account.country).to eq("CZ")
        expect(flash[:notice]).to eq "You have successfully connected your Stripe account!"
        expect(response).to redirect_to settings_payments_url
      end
    end

    context "when there are errors" do
      it "handles already connected Stripe accounts" do
        post :stripe
        expect(user.reload.stripe_connect_account).to be_present

        user2 = create(:user)
        sign_in user2

        set_session_data
        post :stripe

        expect(user2.stripe_connect_account).to be_nil
        expect(flash[:alert]).to eq "This Stripe account has already been linked to a Gumroad account."
        expect(response).to redirect_to settings_payments_url
      end

      it "allows connecting after original account is deleted" do
        post :stripe
        user.stripe_connect_account.delete_charge_processor_account!

        user2 = create(:user)
        sign_in user2

        set_session_data
        post :stripe

        expect(user2.reload.stripe_connect_account).to be_present
        expect(flash[:notice]).to eq "You have successfully connected your Stripe account!"
        expect(response).to redirect_to settings_payments_url
      end

      it "handles merchant account creation failures" do
        allow_any_instance_of(MerchantAccount).to receive(:save).and_return false

        post :stripe

        expect(user.stripe_connect_account).to be_nil
        expect(flash[:alert]).to eq "There was an error connecting your Stripe account with Gumroad."
        expect(response).to redirect_to settings_payments_url
      end

      it "handles invalid session data" do
        session[:stripe_connect_data] = nil

        post :stripe

        expect(flash[:alert]).to eq "Invalid OAuth session"
        expect(response).to redirect_to settings_payments_url
      end
    end

    context "when not authenticated" do
      it "requires authentication" do
        sign_out user

        post :stripe

        expect(response).to redirect_to "/login?next=%2Foauth_completions%2Fstripe"
      end
    end

    it "cleans up session data after completion" do
      post :stripe

      expect(session[:stripe_connect_data]).to be_nil
    end
  end
end
