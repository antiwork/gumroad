# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe SignupController, type: :controller, inertia: true do
  render_views

  before :each do
    request.env["devise.mapping"] = Devise.mappings[:user]
  end

  describe "GET new" do
    describe "Sign up and connect to OAuth app" do
      before do
        @oauth_application = create(:oauth_application_valid)
        @next_url = oauth_authorization_path(client_id: @oauth_application.uid, redirect_uri: @oauth_application.redirect_uri, scope: "edit_products")
      end

      it "returns the page successfully, sets the props correctly and sets noindex header" do
        get :new, params: { next: @next_url }

        expect(response).to be_successful
        expect(assigns[:application]).to eq @oauth_application
        expect(inertia.component).to eq("Signup/New")
        expect(inertia.props[:email]).to be_nil
        expect(inertia.props[:application_name]).to eq(@oauth_application.name)
        expect(inertia.props[:recaptcha_site_key]).to eq(GlobalConfig.get("RECAPTCHA_SIGNUP_SITE_KEY"))
        expect(response.headers["X-Robots-Tag"]).to eq "noindex"
      end

      def signup_props
        referrer = User.find_by_username(params[:referrer]) if params[:referrer].present?
        number_of_creators, total_made = $redis.mget(RedisKey.number_of_creators, RedisKey.total_made)
        login_props.merge(
          recaptcha_site_key: GlobalConfig.get("RECAPTCHA_SIGNUP_SITE_KEY"),
          referrer: referrer ? {
            id: referrer.external_id,
            name: referrer.name_or_username,
          } : nil,
          stats: {
            number_of_creators: number_of_creators.to_i,
            total_made: total_made.to_i,
          },
        )
      end

      context "when an email is provided in the params" do
        it "sets the email in the props" do
          get :new, params: { email: "test@example.com" }
          expect(inertia.props[:email]).to eq "test@example.com"
        end
      end

      context "when an email is present in the next parameter" do
        it "sets the email in the props" do
          get :new, params: { next: settings_team_invitations_path(email: "test@example.com", format: :json) }
          expect(inertia.props[:email]).to eq "test@example.com"
        end
      end

      context "when a referrer is provided in the params" do
        let(:referrer) { create(:user, username: "testreferrer") }

        it "sets the referrer in the props" do
          get :new, params: { referrer: referrer.username }
          expect(inertia.props[:referrer]).to eq({
                                                   id: referrer.external_id,
                                                   name: referrer.name_or_username,
                                                 })
        end
      end

      context "when stats are present in Redis" do
        before do
          $redis.mset(RedisKey.number_of_creators, 100, RedisKey.total_made, 1000000)
        end

        after do
          $redis.del(RedisKey.number_of_creators)
          $redis.del(RedisKey.total_made)
        end

        it "sets the stats in the props" do
          get :new
          expect(inertia.props[:stats]).to eq({
                                                number_of_creators: 100,
                                                total_made: 1000000,
                                              })
        end
      end

      context "when next param does not start with /oauth/authorize" do
        it "sets noindex header" do
          get :new, params: { next: "invalid-url" }
          expect(response.headers["X-Robots-Tag"]).to be_nil
        end
      end
    end
  end

  describe "POST create", :vcr do
    describe "user already exists" do
      before do
        @user = create(:user, password: "password")
      end

      context "when two factor authentication is disabled for the user" do
        it "signs in as user" do
          post "create", params: { user: { email: @user.email, password: "password" } }

          expect(response).to redirect_to(dashboard_path)
          expect(controller.user_signed_in?).to eq true
        end

        it "returns json response" do
          post "create", params: { user: { email: @user.email, password: "password" } }, format: :json

          expect(response.parsed_body["success"]).to be(true)
          expect(response.parsed_body["redirect_location"]).to eq(dashboard_path)
        end
      end

      context "when two factor authentication is enabled for the user" do
        it "sets the user_id in session and redirects for two factor authentication" do
          @user.update!(two_factor_authentication_enabled: true)
          post "create", params: { user: { email: @user.email, password: "password" } }

          expect(session[:verify_two_factor_auth_for]).to eq @user.id
          expect(response).to redirect_to(two_factor_authentication_path(next: dashboard_path))
          expect(controller.user_signed_in?).to eq false
        end
      end
    end

    it "creates a user" do
      user = build(:user, password: "password")
      post "create", params: { user: { email: user.email, password: "password" } }

      expect(response).to redirect_to(dashboard_path)

      last_user = User.last
      expect(last_user.email).to eq user.email
      last_user.valid_password?("password")
      expect(last_user.confirmed?).to be(false)
      expect(last_user.check_merchant_account_is_linked).to be(false)
    end

    it "creates a user and returns json response" do
      user = build(:user, password: "password")
      post "create", params: { user: { email: user.email, password: "password" } }, format: :json

      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body["redirect_location"]).to eq(dashboard_path)
    end

    it "sets two factor authenticated" do
      expect(controller).to receive(:remember_two_factor_auth).and_call_original

      user = build(:user, password: "password")
      post :create, params: { user: { email: user.email, password: "password" } }

      expect(response).to redirect_to(dashboard_path)
    end

    describe "Sign up and connect to OAuth app" do
      before do
        @user = build(:user, password: "password")
        oauth_application = create(:oauth_application_valid)
        @next_url = oauth_authorization_path(client_id: oauth_application.uid, redirect_uri: oauth_application.redirect_uri, scope: "edit_products")
      end

      it "redirects to the OAuth authorization path after successful login" do
        post "create", params: { user: { email: @user.email, password: "password" }, next: @next_url }

        expect(response).to redirect_to(CGI.unescape(@next_url))
      end
    end

    describe "tos agreement" do
      describe "signup on a page that displayed the terms notice" do
        let(:params) do
          {
            user: {
              email: generate(:email),
              password: "password",
              terms_accepted: true
            }
          }
        end

        it "saves a tos agreement record for the user with their IP" do
          @request.remote_ip = "192.168.0.1"
          post("create", params:)
          user = User.last
          expect(user.tos_agreements.count).to eq(1)
          expect(user.tos_agreements.last.ip).to eq("192.168.0.1")
        end
      end

      describe "signup on a page that did not display the terms notice" do
        let(:params) do
          {
            user: {
              email: generate(:email),
              password: "password"
            }
          }
        end

        it "does not save a tos agreement record for the user with their IP" do
          post("create", params:)
          user = User.last
          expect(user.tos_agreements.count).to eq(0)
        end
      end
    end

    it "creates a global affiliate record" do
      user = build(:user, password: "password")
      post "create", params: { user: { email: user.email, password: "password" } }
      user = User.last
      expect(user.global_affiliate).to be_present
    end

    it "saves the user even when a payment made with a transient client token is expired" do
      allow_any_instance_of(CardParamsHelper).to receive(:build_chargeable).and_raise(ChargeProcessorInvalidRequestError)

      user = build(:user, password: "password")
      expect do
        post "create", params: { user: { email: user.email, password: "password" } }
      end.to change { User.count }.by(1)

      last_user = User.last
      expect(last_user.email).to eq user.email
      last_user.valid_password?("password")
      expect(last_user.confirmed?).to be(false)
    end

    it "does not create user if user payload is not given" do
      post "create"
      expect(response).to redirect_to(signup_path)
      expect(flash[:warning]).to eq "Please provide a valid email address."
    end

    it "returns json error if user payload is not given" do
      post "create", format: :json
      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["error_message"]).to eq "Please provide a valid email address."
    end

    it "turns notifications off the user if the user is from Canada" do
      @request.env["REMOTE_ADDR"] = "76.66.210.142"
      user = build(:user, password: "password")
      post "create", params: { user: { email: user.email, password: "password" } }
      last_user = User.last
      expect(last_user.announcement_notification_enabled).to eq false
    end

    it "creates a signup event" do
      @request.remote_ip = "12.12.128.128"
      user = build(:user, password: "password")
      post "create", params: { user: { email: user.email, password: "password" } }

      new_user = User.find_by(email: user.email)
      expect(SignupEvent.last.user_id).to eq new_user.id
      expect(SignupEvent.last.ip_address).to eq "12.12.128.128"
    end

    it "saves the account created ip" do
      @request.remote_ip = "12.12.128.128"
      @user = build(:user, password: "password")
      post "create", params: { user: { email: @user.email, password: "password" } }
      expect(User.last.account_created_ip).to eq "12.12.128.128"
    end

    it "doesn't redirect externally and deals with badly-formed referer URLs" do
      purchase = create(:purchase)
      referrer_path = "?__utma=11926824.84037407.1424232314.1424240345.1425108120.4"
      referrer_path += "&__utmb=11926824.3.9.1425108369109&__utmc=11926824&__utmx=-&__utmz=11926824.1425108120.4.4.utmcsr=english_blog|"
      referrer_path += "utmccn=msr2015_companion|utmcmd=banner|utmcct=in_300x600_banner_ad&__utmv=-&__utmk=223657947"
      referrer_url = [request.protocol, "badguy.com", referrer_path].join
      request.headers["HTTP_REFERER"] = referrer_url
      expect do
        post :create, params: { user:
          { email: purchase.email, add_purchase_to_existing_account: false, buyer_signup: true, password: "password", purchase_id: purchase.external_id } }
        expect(response).to redirect_to(Addressable::URI.escape(referrer_path))
      end.to change { User.count }.by(1)
    end

    describe "invites" do
      describe "external_id" do
        before do
          @user = create(:user)
          create(:invite, sender_id: @user.id, receiver_email: "anish@gumroad.com")
        end

        it "updates invite to signed up and save receiver_id" do
          expect(Invite.last.invite_state).to eq "invitation_sent"
          post "create", params: { user: { email: "anish@gumroad.com", password: "password" }, referral: @user.external_id }
          expect(Invite.last.invite_state).to eq "signed_up"
          expect(Invite.last.receiver_id).to eq User.last.id
        end

        it "creates a new invite and make it signed up with receiver_id" do
          expect { post "create", params: { user: { email: "anish+2@gumroad.com", password: "password" }, referral: @user.external_id } }.to change {
            Invite.count
          }.by(1)
          expect(Invite.last.sender_id).to eq @user.id
          expect(Invite.last.invite_state).to eq "signed_up"
          expect(Invite.last.receiver_email).to eq "anish+2@gumroad.com"
          expect(Invite.last.receiver_id).to eq User.last.id
        end

        it "does not create a new invite" do
          expect { post "create", params: { user: { email: "anish@gumroad.com", password: "password" } } }.to change {
            Invite.count
          }.by(0)
        end

        it "does not change any existing invites" do
          expect(Invite.last.invite_state).to eq "invitation_sent"
          post "create", params: { user: { email: "anish@gumroad.com", password: "password" } }
          expect(Invite.last.invite_state).to eq "invitation_sent"
          expect(Invite.last.receiver_id).to be(nil)
        end
      end
    end

    it "links user purchase and credit card", :vcr do
      # Provided a credit card and purchase made, a user that signs up for a
      # buyer side account will be linked to these other models.
      # Signup with CC is without CVC because it's done automatically in the background when user enters a password
      # after having completed a purchase (that clears the CVC).
      card_data = StripePaymentMethodHelper.success.without(:cvc)
      purchase = create(:purchase, stripe_fingerprint: card_data.to_stripejs_fingerprint)
      params = card_data.to_stripejs_params.merge!(purchase_id: ObfuscateIds.encrypt(purchase.id))
      user = build(:user, password: "password")
      # Ensure purchase and card are not linked to it at this point
      expect(user.purchases).to be_empty
      expect(user.credit_card).to be(nil)

      user_params = { email: user.email, password: "password" }
      user_params.update(params)

      post "create", params: { user: user_params }
      last_user = User.last
      expect(last_user.email).to eq user.email
      expect(last_user.purchases.first.id).to eq purchase.id
      expect(last_user.credit_card.id).to_not be(nil)
      expect(last_user.credit_card.expiry_month).to eq 12
      expect(last_user.credit_card.expiry_year).to eq 2023
    end

    it "links user purchase but not credit card if fingerprint different to purchase credit card", :vcr do
      # Provided a credit card and purchase made, a user that signs up for a
      # buyer side account will be linked to these other models.
      # Signup with CC is without CVC because it's done automatically in the background when user enters a password
      # after having completed a purchase (that clears the CVC).
      # To limit risk, we only accept the CC number on signup, if it's with a purchase
      # that the CC has been used on.
      card_data = StripePaymentMethodHelper.success.without(:cvc)
      purchase = create(:purchase, stripe_fingerprint: "some-other-finger-print")
      params = card_data.to_stripejs_params.merge!(purchase_id: ObfuscateIds.encrypt(purchase.id))
      user = build(:user, password: "password")
      # Ensure purchase and card are not linked to it at this point
      expect(user.purchases).to be_empty
      expect(user.credit_card).to be(nil)

      user_params = { email: user.email, password: "password" }
      user_params.update(params)

      post "create", params: { user: user_params }
      last_user = User.last
      expect(last_user.email).to eq user.email
      expect(last_user.purchases.first.id).to eq purchase.id
      expect(last_user.credit_card).to be(nil)
    end

    it "links past purchases by email if they're not linked to purchasers already" do
      user = build(:user, password: "password")
      purchase = create(:purchase, email: user.email)
      create(:purchase, email: user.email, purchaser: create(:user))
      expect(user.purchases).to be_empty

      post "create", params: { user: { email: user.email, password: "password" } }
      last_user = User.last
      expect(last_user.email).to eq user.email
      expect(last_user.purchases.count).to eq 1
      expect(last_user.purchases.first.id).to eq purchase.id
    end

    it "rejects mass assignment of privileged attributes" do
      params = {
        user: {
          email: generate(:email),
          password: "password",
          verified: true,
          user_risk_state: "compliant",
          tos_violation_reason: "fraud",
        }
      }
      post "create", params:, format: :json
      last_user = User.last
      expect(last_user).to be_present
      expect(last_user.verified).to be_falsey
      expect(last_user.user_risk_state).not_to eq "compliant"
      expect(last_user.tos_violation_reason).to be_nil
    end

    it "associates the preorder with the newly created user", :vcr do
      purchase = create(:purchase)
      preorder = create(:preorder)
      purchase.preorder = preorder
      purchase.save
      params = StripePaymentMethodHelper.success.to_stripejs_params.merge!(purchase_id: ObfuscateIds.encrypt(purchase.id))
      user = build(:user, password: "password")
      user_params = { email: user.email, password: "password" }
      user_params.update(params)

      post "create", params: { user: user_params }

      new_user = User.last
      expect(new_user.preorders_bought).to eq [preorder]
    end
  end

  describe "POST 'save_to_library'" do
    describe "email already taken" do
      before do
        @user = create(:user)
        @purchase = create(:purchase)
        @url_redirect = create(:url_redirect, purchase: @purchase)
      end

      it "failed and has email taken error" do
        post :save_to_library, params: { user: { email: @user.email, password: "blah123", purchase_id: @purchase.external_id } }
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["error_message"]).to eq "An account already exists with this email.".html_safe
      end
    end

    describe "email not yet taken" do
      before do
        @purchase = create(:purchase)
      end

      it "signs up the user" do
        post :save_to_library, params: { user: { email: @purchase.email, password: "blah123", purchase_id: @purchase.external_id } }
        expect(response.parsed_body["success"]).to be(true)
        expect(response.parsed_body["error_message"]).to be(nil)

        user = User.last
        expect(user.email).to eq @purchase.email
      end

      it "assigns them the correct purchase" do
        expect { post :save_to_library, params: { user: { email: @purchase.email, password: "blah123", purchase_id: @purchase.external_id } } }
          .to change { @purchase.reload.purchaser.nil? }.from(true).to(false)
      end

      it "fails because password too short" do
        post :save_to_library, params: { user: { email: @purchase.email, password: "bla", purchase_id: @purchase.external_id } }
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["error_message"]).to eq "Password is too short (minimum is 4 characters)"
      end

      it "redirects to the library" do
        post :save_to_library, params: { user: { email: @purchase.email, password: "blah123", purchase_id: @purchase.external_id } }
        expect(response.parsed_body["success"]).to be(true)
        expect(response.parsed_body["error_message"]).to be(nil)
      end

      it "associates past purchases with the same email to the new user" do
        purchase1 = create(:purchase, email: @purchase.email)
        purchase2 = create(:purchase, email: @purchase.email)
        expect(purchase1.purchaser_id).to be_nil
        expect(purchase2.purchaser_id).to be_nil

        post :save_to_library, params: { user: { email: @purchase.email, password: "blah123", purchase_id: @purchase.external_id } }
        expect(response).to be_successful

        user = User.last
        [@purchase, purchase1, purchase2].each do |purchase|
          expect(purchase.reload.purchaser_id).to eq(user.id)
        end
      end

      it "creates a global affiliate record" do
        post :save_to_library, params: { user: { email: @purchase.email, password: "blah123", purchase_id: @purchase.external_id } }

        user = User.last
        expect(user.global_affiliate).to be_present
      end
    end
  end
end
