# frozen_string_literal: true

require "spec_helper"

describe User::OmniauthCallbacksController do
  ACCOUNT_DELETION_ERROR_MSG = "You cannot log in because your account was permanently deleted. "\
                               "Please sign up for a new account to start selling!"

  before do
    request.env["devise.mapping"] = Devise.mappings[:user]
  end

  def fetch_json(service)
    JSON.parse(File.open("#{Rails.root}/spec/support/fixtures/#{service}_omniauth.json").read)
  end

  def safe_redirect_path(path, allow_subdomain_host: true)
    SafeRedirectPathService.new(path, request, allow_subdomain_host:).process
  end

  describe "#stripe_connect", :vcr do
    let(:stripe_uid) { "acct_1SOb0DEwFhlcVS6d" }
    let(:stripe_auth) do
      OmniAuth::AuthHash.new(
        uid: stripe_uid,
        credentials: { token: "tok" },
        info: { email: "stripe.connect@gum.co", stripe_publishable_key: "pk_key" },
        extra: { extra_info: { country: "SG" }, raw_info: { country: "SG" } }
      )
    end

    before do
      request.env["omniauth.auth"] = stripe_auth
    end

    shared_examples "stripe connect user creation" do
      it "creates user if none exists" do
        expect { post :stripe_connect }.to change { User.count }.by(1)

        user = User.last
        expect(user.email).to eq("stripe.connect@gum.co")
        expect(user.confirmed?).to be true
        expect(response).to redirect_to safe_redirect_path(two_factor_authentication_path(next: oauth_completions_stripe_path))
      end

      it "redirects directly to completion when user has no email" do
        request.env["omniauth.auth"]["info"].delete "email"
        request.env["omniauth.auth"]["extra"]["raw_info"].delete "email"

        expect { post :stripe_connect }.to change { User.count }.by(1)

        user = User.last
        expect(user.email).to be_nil
        expect(controller.user_signed_in?).to be true
        expect(response).to redirect_to safe_redirect_path(oauth_completions_stripe_path)
      end

      it "requires 2FA when user has email" do
        post :stripe_connect

        user = User.last
        expect(user.email).to eq("stripe.connect@gum.co")
        expect(controller.user_signed_in?).to be false
        expect(response).to redirect_to safe_redirect_path(two_factor_authentication_path(next: oauth_completions_stripe_path))
      end

      it "does not create a new user if the email is already taken" do
        create(:user, email: "stripe.connect@gum.co")

        expect { post :stripe_connect }.not_to change { User.count }

        expect(response).to redirect_to safe_redirect_path(two_factor_authentication_path(next: oauth_completions_stripe_path))
      end
    end

    context "when referer is payments settings" do
      before do
        request.env["omniauth.params"] = { "referer" => settings_payments_path }
      end

      it "throws error if stripe account is from an unsupported country" do
        request.env["omniauth.auth"]["uid"] = "acct_1SOk0BEsYunTuUHD"
        user = create(:user)
        allow(controller).to receive(:current_user).and_return(user)

        post :stripe_connect

        expect(user.reload.stripe_connect_account).to be(nil)
        expect(flash[:alert]).to eq "Sorry, Stripe Connect is not supported in Malaysia yet."
        expect(response).to redirect_to settings_payments_url
      end

      it "throws error if creator already has another stripe account connected" do
        user = create(:user)
        stripe_connect_account = create(:merchant_account_stripe_connect, user:, charge_processor_merchant_id: "acct_1SOb0DEwFhlcVS6d")
        allow(controller).to receive(:current_user).and_return(user)

        expect { post :stripe_connect }.not_to change { MerchantAccount.count }

        expect(user.reload.stripe_connect_account).to eq(stripe_connect_account)
        expect(flash[:alert]).to eq "You already have another Stripe account connected with your Gumroad account."
        expect(response).to redirect_to settings_payments_url
      end
    end

    context "when referer is login" do
      let(:referer) { "login" }
      before { request.env["omniauth.params"] = { "referer" => login_path } }

      include_examples "stripe connect user creation"

      it "does not log in admin user" do
        create(:merchant_account_stripe_connect, user: create(:admin_user), charge_processor_merchant_id: stripe_uid)

        post :stripe_connect

        expect(flash[:alert]).to eq "You're an admin, you can't login with Stripe."
        expect(response).to redirect_to login_url
      end

      it "does not allow user to login if the account is deleted" do
        create(:merchant_account_stripe_connect, user: create(:user, deleted_at: Time.current), charge_processor_merchant_id: stripe_uid)

        post :stripe_connect

        expect(flash[:alert]).to eq ACCOUNT_DELETION_ERROR_MSG
        expect(response).to redirect_to login_url
      end
    end

    context "when referer is signup" do
      let(:referer) { "signup" }
      before { request.env["omniauth.params"] = { "referer" => signup_path } }

      include_examples "stripe connect user creation"

      it "associates past purchases with the same email to the new user" do
        email = request.env["omniauth.auth"]["info"]["email"]
        purchase1 = create(:purchase, email:)
        purchase2 = create(:purchase, email:)
        expect(purchase1.purchaser_id).to be_nil
        expect(purchase2.purchaser_id).to be_nil

        post :stripe_connect

        user = User.last
        expect(user.email).to eq("stripe.connect@gum.co")
        expect(purchase1.reload.purchaser_id).to eq(user.id)
        expect(purchase2.reload.purchaser_id).to eq(user.id)
        expect(response).to redirect_to safe_redirect_path(two_factor_authentication_path(next: oauth_completions_stripe_path))
      end
    end

    context "when disable_stripe_signup feature flag is active" do
      before do
        Feature.activate(:disable_stripe_signup)
        request.env["omniauth.params"] = { "referer" => signup_path }
      end

      after { Feature.deactivate(:disable_stripe_signup) }

      it "does not allow new users to sign up via Stripe" do
        expect { post :stripe_connect }.not_to change { User.count }

        expect(flash[:alert]).to eq "Sorry, we could not find an account associated with that Stripe account."
        expect(response).to redirect_to signup_url
      end

      it "allows existing users with Stripe account to log in" do
        user = create(:user, email: "stripe.connect@gum.co")
        create(:merchant_account_stripe_connect, user:, charge_processor_merchant_id: stripe_uid)

        expect { post :stripe_connect }.not_to change { User.count }

        expect(response).to redirect_to safe_redirect_path(two_factor_authentication_path(next: oauth_completions_stripe_path))
      end

      it "allows existing users with matching email (without Stripe connected) to log in" do
        create(:user, email: "stripe.connect@gum.co")

        expect { post :stripe_connect }.not_to change { User.count }

        expect(response).to redirect_to safe_redirect_path(two_factor_authentication_path(next: oauth_completions_stripe_path))
      end

      it "allows existing users without email to log in" do
        user = create(:user)
        user.update_column(:email, nil)
        create(:merchant_account_stripe_connect, user:, charge_processor_merchant_id: stripe_uid)

        expect { post :stripe_connect }.not_to change { User.count }

        expect(controller.user_signed_in?).to be true
        expect(response).to redirect_to safe_redirect_path(oauth_completions_stripe_path)
      end
    end
  end

  describe "#facebook" do
    before do
      OmniAuth.config.mock_auth[:facebook] = OmniAuth::AuthHash.new fetch_json("facebook")
      request.env["omniauth.params"] = { state: true }
      request.env["omniauth.auth"] = OmniAuth.config.mock_auth[:facebook]
    end

    it "creates user if none exists" do
      expect do
        post :facebook
      end.to change { User.count }.by(1)
      user = User.last
      expect(user.name).to eq "Sidharth Shanker"
      expect(user.email).to match "sps2133@columbia.edu"
      expect(user.global_affiliate).to be_present
    end

    it "associates past purchases with the same email to the new user" do
      email = request.env["omniauth.auth"]["info"]["email"]
      purchase1 = create(:purchase, email:)
      purchase2 = create(:purchase, email:)
      expect(purchase1.purchaser_id).to be_nil
      expect(purchase2.purchaser_id).to be_nil

      post :facebook

      user = User.last
      expect(purchase1.reload.purchaser_id).to eq(user.id)
      expect(purchase2.reload.purchaser_id).to eq(user.id)
    end

    it "creates user even if there's no email address" do
      request.env["omniauth.auth"]["info"].delete "email"
      request.env["omniauth.auth"]["extra"]["raw_info"].delete "email"
      post :facebook
      user = User.last
      expect(user.name).to eq "Sidharth Shanker"
      expect(user.email).to_not be_present
    end

    describe "user is admin" do
      it "does not log in user" do
        allow(User).to receive(:new).and_return(create(:admin_user))
        post :facebook
        expect(flash[:alert]).to eq "You're an admin, you can't login with Facebook."
        expect(response).to redirect_to login_url
      end
    end

    context "when user is marked as deleted" do
      let!(:user) { create(:user, facebook_uid: "509129169", deleted_at: Time.current) }

      it "does not allow user to login" do
        post :facebook

        expect(flash[:alert]).to eq ACCOUNT_DELETION_ERROR_MSG
        expect(response).to redirect_to login_url
      end
    end

    context "when user has 2FA" do
      let!(:user) { create(:user, facebook_uid: "509129169", email: "sps2133@example.com", two_factor_authentication_enabled: true) }

      it "does not allow user to login with FB only" do
        post :facebook
        expect(response).to redirect_to CGI.unescape(two_factor_authentication_path(next: dashboard_path))
      end

      it "keeps referral intact" do
        post :facebook, params: { referer: balance_path }
        expect(response).to redirect_to CGI.unescape(two_factor_authentication_path(next: balance_path))
      end
    end

    describe "no facebook account connected" do
      it "links facebook account to existing account" do
        @user = create(:user)
        OmniAuth.config.mock_auth[:facebook] = OmniAuth::AuthHash.new fetch_json("facebook")
        request.env["omniauth.params"] = { "state" => "link_facebook_account" }
        request.env["omniauth.auth"] = OmniAuth.config.mock_auth[:facebook]
        allow(controller).to receive(:current_user).and_return(@user)
        post :facebook
        @user.reload
        expect(@user.facebook_uid).to_not be(nil)
      end

      describe "facebook account connected to different account" do
        before do
          @existing_facebook_account = create(:user, facebook_uid: fetch_json("facebook")["uid"])
          @new_user = create(:user)
          OmniAuth.config.mock_auth[:facebook] = OmniAuth::AuthHash.new fetch_json("facebook")
          request.env["omniauth.params"] = { "state" => "link_facebook_account" }
          request.env["omniauth.auth"] = OmniAuth.config.mock_auth[:facebook]

          sign_in @new_user
        end

        it "does not link accounts if the facebook account is already linked to a gumroad account" do
          expect do
            post :facebook
          end.to_not change {
            @new_user.reload.facebook_uid
          }
        end

        it "sets the correct flash message" do
          post :facebook
          expect(flash[:alert]).to eq "Your Facebook account has already been linked to a Gumroad account."
          expect(response).to redirect_to user_url(@new_user)
        end
      end
    end

    describe "has no 2FA email" do
      before do
        user = create(:user)
        allow(User).to receive(:new).and_return(user)
        user.email = nil
        user.save!(validate: false)
      end

      it "redirects directly to referrer", :vcr do
        post :facebook, params: { referer: balance_path }
        expect(response).to redirect_to balance_path
      end

      it "redirects directly to dashboard", :vcr do
        post :facebook
        expect(response).to redirect_to dashboard_path
      end
    end

    context "when user is not created" do
      before do
        allow(User).to receive(:find_for_facebook_oauth).and_return(User.new)
      end

      it "redirects to the signup page with an error flash message" do
        post :facebook

        expect(flash[:alert]).to eq "Sorry, something went wrong. Please try again."
        expect(response).to redirect_to signup_path
      end
    end
  end

  describe "#twitter" do
    before do
      OmniAuth.config.mock_auth[:twitter] = OmniAuth::AuthHash.new fetch_json("twitter")
      request.env["omniauth.auth"] = fetch_json("twitter")
      request.env["omniauth.params"] = { "state" => true }
    end

    it "creates user if none exists", :vcr do
      expect do
        post :twitter
      end.to change { User.count }.by(1)

      user = User.last
      expect(user.name).to match "Sidharth Shanker"
      expect(user.email).to eq nil
      expect(user.global_affiliate).to be_present
    end

    context "when user is admin" do
      it "does not allow user to login" do
        allow(User).to receive(:new).and_return(create(:admin_user))

        post :twitter

        expect(flash[:alert]).to eq "You're an admin, you can't login with Twitter."
        expect(response).to redirect_to login_path
      end
    end

    context "when user is marked as deleted" do
      let!(:user) { create(:user, twitter_user_id: "279418691", deleted_at: Time.current) }

      it "does not allow user to login" do
        post :twitter

        expect(flash[:alert]).to eq ACCOUNT_DELETION_ERROR_MSG
        expect(response).to redirect_to login_path
      end
    end

    context "when user has 2FA" do
      let!(:user) { create(:user, twitter_user_id: "279418691", email: "sps2133@example.com", two_factor_authentication_enabled: true) }

      it "does not allow user to login with Twitter only" do
        post :twitter
        expect(response).to redirect_to CGI.unescape(two_factor_authentication_path(next: dashboard_path))
      end

      it "keeps referral intact" do
        post :twitter, params: { referer: balance_path }
        expect(response).to redirect_to CGI.unescape(two_factor_authentication_path(next: balance_path))
      end
    end

    describe "linking account" do
      it "links twitter account to existing account", :vcr do
        @user = create(:user, name: "Tim Lupton", bio: "A regular guy")
        request.env["omniauth.params"] = { "state" => "link_twitter_account" }
        OmniAuth.config.mock_auth[:twitter] = OmniAuth::AuthHash.new fetch_json("twitter")
        request.env["omniauth.auth"] = OmniAuth.config.mock_auth[:twitter]
        allow(controller).to receive(:current_user).and_return(@user)
        post :twitter
        @user.reload
        expect(@user.name).to eq "Tim Lupton"
        expect(@user.bio).to eq "A regular guy"
        expect(@user.twitter_oauth_token).to_not be(nil)
        expect(@user.twitter_oauth_secret).to_not be(nil)
        expect(@user.twitter_handle).to_not be(nil)
      end

      it "updates the Twitter OAuth credentials on account creation", :vcr do
        user = create(:user)
        allow(User).to receive(:new).and_return(user)

        OmniAuth.config.mock_auth[:twitter] = OmniAuth::AuthHash.new fetch_json("twitter")
        request.env["omniauth.auth"] = OmniAuth.config.mock_auth[:twitter]

        post :twitter

        user.reload
        expect(user.twitter_oauth_token).to be_present
        expect(user.twitter_oauth_secret).to be_present
      end
    end

    describe "has no 2FA email" do
      before do
        user = create(:user)
        allow(User).to receive(:new).and_return(user)
        user.email = nil
        user.save!(validate: false)
      end

      it "redirects to the settings page and ignores referrer", :vcr do
        post :twitter, params: { referer: balance_path }

        expect(flash[:warning]).to eq "Please enter an email address!"
        expect(response).to redirect_to settings_main_path
      end
    end

    context "when the user has unconfirmed email" do
      before do
        user = create(:user)
        allow(User).to receive(:new).and_return(user)
        user.email = nil
        user.unconfirmed_email = "test@gumroad.com"
        user.save!(validate: false)
      end

      it "redirects to the settings page with the correct warning flash message", :vcr do
        post :twitter

        expect(flash[:warning]).to eq "Please confirm your email address"
        expect(response).to redirect_to settings_main_path
      end
    end

    context "when user is not created" do
      before do
        allow(User).to receive(:find_or_create_for_twitter_oauth!).and_return(User.new)
      end

      it "redirects to the signup page with an error flash message" do
        post :twitter

        expect(flash[:alert]).to eq "Sorry, something went wrong. Please try again."
        expect(response).to redirect_to signup_path
      end
    end
  end

  describe "#google_oauth2" do
    before do
      OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new fetch_json("google")
      request.env["omniauth.auth"] = fetch_json("google")
      request.env["omniauth.params"] = { "state" => true }
    end

    it "creates user if none exists", :vcr do
      expect do
        post :google_oauth2
      end.to change { User.count }.by(1)

      user = User.last
      expect(user.name).to match "Paulius Dragunas"
      expect(user.global_affiliate).to be_present
    end

    context "when user is admin" do
      it "does not allow user to login" do
        allow(User).to receive(:new).and_return(create(:admin_user))

        post :google_oauth2

        expect(flash[:alert]).to eq "You're an admin, you can't login with Google."
        expect(response).to redirect_to login_path
      end
    end

    context "when user is marked as deleted" do
      let!(:user) { create(:user, google_uid: "101656774483284362141", deleted_at: Time.current) }

      it "does not allow user to login" do
        post :google_oauth2

        expect(flash[:alert]).to eq ACCOUNT_DELETION_ERROR_MSG
        expect(response).to redirect_to login_path
      end
    end

    context "when user has 2FA" do
      let!(:user) { create(:user, google_uid: "101656774483284362141", email: "pdragunas@example.com", two_factor_authentication_enabled: true) }

      it "does not allow user to login with Google only" do
        post :google_oauth2
        expect(response).to redirect_to CGI.unescape(two_factor_authentication_path(next: dashboard_path))
      end

      it "keeps referral intact" do
        post :google_oauth2, params: { referer: balance_path }
        expect(response).to redirect_to CGI.unescape(two_factor_authentication_path(next: balance_path))
      end
    end

    context "linking account" do
      it "links google account to existing account", :vcr do
        @user = create(:user, email: "pdragunas@example.com")

        OmniAuth.config.mock_auth[:google] = OmniAuth::AuthHash.new fetch_json("google")
        request.env["omniauth.auth"] = OmniAuth.config.mock_auth[:google]
        allow(controller).to receive(:current_user).and_return(@user)

        post :google_oauth2

        @user.reload

        expect(@user.name).to eq "Paulius Dragunas"
        expect(@user.email).to eq "pdragunas@example.com"
        expect(@user.google_uid).to eq "101656774483284362141"
      end
    end

    context "when user is not created" do
      shared_examples "redirects to signup with error message" do
        it "redirects to the signup page with an error flash message" do
          post :google_oauth2

          expect(flash[:alert]).to eq "Sorry, something went wrong. Please try again."
          expect(response).to redirect_to signup_path
        end
      end

      context "when the user is not persisted" do
        before { allow(User).to receive(:find_or_create_for_google_oauth2).and_return(User.new) }

        include_examples "redirects to signup with error message"
      end

      context "when there's an error creating the user" do
        before { allow(User).to receive(:find_or_create_for_google_oauth2).and_return(nil) }

        include_examples "redirects to signup with error message"
      end
    end
  end
end
