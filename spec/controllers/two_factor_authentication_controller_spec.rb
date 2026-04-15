# frozen_string_literal: true

require "spec_helper"
require "shared_examples/merge_guest_cart_with_user_cart"
require "inertia_rails/rspec"

describe TwoFactorAuthenticationController, type: :controller, inertia: true do
  render_views
  include UsersHelper

  before do
    @user = create(:user, two_factor_authentication_enabled: true)
  end

  shared_examples_for "redirect to signed_in path for html request" do
    context "when two factor authentication can be skipped" do
      before do
        sign_in @user
        controller.reset_two_factor_auth_login_session
        allow(controller).to receive(:skip_two_factor_authentication?).and_return(true)
      end

      context "when request format is html" do
        it "redirects to signed_in_user_home" do
          call_action

          expect(response).to redirect_to(signed_in_user_home(@user))
        end
      end
    end
  end

  shared_examples_for "validate user_id in params for html request" do |action|
    it "raises ActionController::RoutingError when user_id is invalid" do
      expect do
        get action, params: { user_id: "invalid" }, format: :html
      end.to raise_error(ActionController::RoutingError, "Not Found")
    end
  end

  shared_examples_for "sign in as user and remember two factor authentication status" do
    before do
      controller.prepare_for_two_factor_authentication(@user)
    end

    it "signs in the user" do
      expect(controller).to receive(:sign_in).with(@user).and_call_original

      call_action

      expect(controller.logged_in_user).to eq @user
    end

    it "invokes remember_two_factor_auth" do
      expect(controller).to receive(:remember_two_factor_auth).and_call_original

      call_action
    end

    it "invokes reset_two_factor_auth_login_session" do
      expect(controller).to receive(:reset_two_factor_auth_login_session).and_call_original

      call_action
    end

    it "confirms the user if the user is not confirmed" do
      @user.update!(confirmed_at: nil)

      call_action

      expect(@user.reload.confirmed?).to eq true
    end
  end

  shared_examples_for "check user in session for html request" do
    it "raises ActionController::RoutingError when user is not found in session" do
      controller.reset_two_factor_auth_login_session

      expect do
        call_action
      end.to raise_error(ActionController::RoutingError, "Not Found")
    end
  end

  describe "GET show" do # GET /two-factor
    include_examples "redirect to signed_in path for html request" do
      subject(:call_action) { get :show }
    end

    include_examples "check user in session for html request" do
      subject(:call_action) { get :show }
    end

    before do
      controller.prepare_for_two_factor_authentication(@user)
    end

    it "renders HTTP success" do
      get :show

      expect(response).to be_successful
    end

    it "sets @user" do
      get :show

      expect(assigns[:user]).to eq @user
    end

    it "renders the Inertia TwoFactorAuthentication/Show component" do
      get :show

      expect(inertia.component).to eq("TwoFactorAuthentication/Show")
      expect(inertia.props[:user_id]).to eq(@user.encrypted_external_id)
      expect(inertia.props[:email]).to eq(@user.email)
      expect(inertia.props[:token]).to eq(User::DEFAULT_AUTH_TOKEN)
    end

    it "sets the page title" do
      get :show

      expect(controller.send(:page_title)).to eq("Two-Factor Authentication")
    end
  end

  describe "POST create" do # POST /two-factor
    it "raises ActionController::RoutingError when user_id is invalid" do
      expect do
        post :create, params: { user_id: "invalid" }
      end.to raise_error(ActionController::RoutingError, "Not Found")
    end

    include_examples "redirect to signed_in path for html request" do
      subject(:call_action) { post :create }
    end

    include_examples "check user in session for html request" do
      subject(:call_action) { post :create }
    end

    before do
      controller.prepare_for_two_factor_authentication(@user)
    end

    context "when authentication token is valid" do
      include_examples "sign in as user and remember two factor authentication status" do
        subject(:call_action) { post :create, params: { token: @user.otp_code, user_id: @user.encrypted_external_id } }
      end

      it "redirects with success message" do
        post :create, params: { token: @user.otp_code, user_id: @user.encrypted_external_id }

        expect(flash[:notice]).to eq "Successfully logged in!"
        expect(response).to redirect_to(controller.send(:login_path_for, @user))
      end

      it_behaves_like "merge guest cart with user cart" do
        let(:user) { @user }
        let(:call_action) { post :create, params: { token: user.otp_code, user_id: user.encrypted_external_id } }
        let(:expected_redirect_location) { controller.send(:login_path_for, user) }
      end
    end

    context "when authentication token is invalid" do
      it "redirects with failure message" do
        post :create, params: { token: "abcdef", user_id: @user.encrypted_external_id }

        expect(flash[:warning]).to eq "Invalid token, please try again."
        expect(response).to redirect_to(two_factor_authentication_path)
      end
    end
  end

  # Request from "Login" link in authentication token email
  describe "GET verify" do # GET /two-factor/verify.html
    include_examples "validate user_id in params for html request", :verify

    include_examples "redirect to signed_in path for html request" do
      subject(:call_action) { get :verify, format: :html }
    end

    before do
      controller.prepare_for_two_factor_authentication(@user)
    end

    context "when authentication token is valid" do
      include_examples "sign in as user and remember two factor authentication status" do
        subject(:call_action) { get :verify, params: { token: @user.otp_code, user_id: @user.encrypted_external_id }, format: :html }
      end

      it "redirects with success message" do
        get :verify, params: { token: @user.otp_code, user_id: @user.encrypted_external_id }, format: :html

        expect(flash[:notice]).to eq "Successfully logged in!"
        expect(response).to redirect_to(controller.send(:login_path_for, @user))
      end
    end

    context "when authentication token is invalid" do
      it "redirects with failure message" do
        get :verify, params: { token: "abcdef", user_id: @user.encrypted_external_id }, format: :html

        expect(flash[:warning]).to eq "Invalid token, please try again."
        expect(response).to redirect_to(two_factor_authentication_path)
      end
    end

    context "when user is not available in session" do
      before do
        controller.reset_two_factor_auth_login_session
      end

      it "redirects to login_path" do
        get :verify, params: { token: @user.otp_code, user_id: @user.encrypted_external_id }, format: :html

        expect(response).to redirect_to(login_url(next: verify_two_factor_authentication_path(token: @user.otp_code, user_id: @user.encrypted_external_id, format: :html)))
      end
    end
  end

  describe "POST resend_authentication_token" do # POST /two-factor/resend_authentication_token
    it "raises ActionController::RoutingError when user_id is invalid" do
      expect do
        post :resend_authentication_token, params: { user_id: "invalid" }
      end.to raise_error(ActionController::RoutingError, "Not Found")
    end

    include_examples "redirect to signed_in path for html request" do
      subject(:call_action) { post :resend_authentication_token }
    end

    include_examples "check user in session for html request" do
      subject(:call_action) { post :resend_authentication_token }
    end

    before do
      controller.prepare_for_two_factor_authentication(@user)
    end

    it "resends the authentication token and redirects with notice" do
      expect do
        post :resend_authentication_token, params: { user_id: @user.encrypted_external_id }
      end.to have_enqueued_mail(TwoFactorAuthenticationMailer, :authentication_token).with(@user.id, email_provider: nil)

      expect(response).to redirect_to(two_factor_authentication_path)
      expect(flash[:notice]).to eq "Resent the authentication token, please check your inbox."
    end

    context "when user has TOTP enabled" do
      before do
        Feature.activate_user(:authenticator_2fa, @user)
        create(:totp_credential, :confirmed, user: @user)
        controller.prepare_for_two_factor_authentication(@user)
      end

      it "does not resend and shows warning" do
        expect do
          post :resend_authentication_token, params: { user_id: @user.encrypted_external_id }
        end.not_to have_enqueued_mail(TwoFactorAuthenticationMailer, :authentication_token)

        expect(response).to redirect_to(two_factor_authentication_path)
        expect(flash[:warning]).to eq "Cannot resend token for authenticator app."
      end
    end

    context "when method is recovery" do
      before do
        Feature.activate_user(:authenticator_2fa, @user)
        create(:totp_credential, :confirmed, user: @user)
        controller.prepare_for_two_factor_authentication(@user)
        controller.two_factor_auth_method = "recovery"
      end

      it "does not resend and shows warning" do
        expect do
          post :resend_authentication_token, params: { user_id: @user.encrypted_external_id }
        end.not_to have_enqueued_mail(TwoFactorAuthenticationMailer, :authentication_token)

        expect(response).to redirect_to(two_factor_authentication_path)
        expect(flash[:warning]).to eq "Cannot resend token for authenticator app."
      end
    end
  end

  describe "POST switch_to_email" do
    include_examples "check user in session for html request" do
      subject(:call_action) { post :switch_to_email }
    end

    before do
      Feature.activate_user(:authenticator_2fa, @user)
      create(:totp_credential, :confirmed, user: @user)
      controller.prepare_for_two_factor_authentication(@user)
    end

    it "switches method to email, sends token, and redirects" do
      expect do
        post :switch_to_email, params: { user_id: @user.encrypted_external_id }
      end.to have_enqueued_mail(TwoFactorAuthenticationMailer, :authentication_token).with(@user.id, email_provider: nil)

      expect(controller.send(:two_factor_auth_method)).to eq("email")
      expect(response).to redirect_to(two_factor_authentication_path)
      expect(flash[:notice]).to eq "Authentication token sent to #{@user.email}."
    end
  end

  describe "POST switch_to_recovery" do
    include_examples "check user in session for html request" do
      subject(:call_action) { post :switch_to_recovery }
    end

    before do
      Feature.activate_user(:authenticator_2fa, @user)
      create(:totp_credential, :confirmed, user: @user)
      controller.prepare_for_two_factor_authentication(@user)
    end

    it "switches method to recovery and redirects" do
      post :switch_to_recovery, params: { user_id: @user.encrypted_external_id }

      expect(controller.send(:two_factor_auth_method)).to eq("recovery")
      expect(response).to redirect_to(two_factor_authentication_path)
    end
  end

  describe "POST switch_to_authenticator" do
    include_examples "check user in session for html request" do
      subject(:call_action) { post :switch_to_authenticator }
    end

    before do
      Feature.activate_user(:authenticator_2fa, @user)
      create(:totp_credential, :confirmed, user: @user)
      controller.prepare_for_two_factor_authentication(@user)
      controller.two_factor_auth_method = "email"
    end

    it "switches method to totp and redirects" do
      post :switch_to_authenticator, params: { user_id: @user.encrypted_external_id }

      expect(controller.send(:two_factor_auth_method)).to eq("totp")
      expect(response).to redirect_to(two_factor_authentication_path)
    end
  end

  context "when user has TOTP enabled" do
    let!(:totp_credential) { create(:totp_credential, :with_recovery_codes, user: @user) }

    before do
      Feature.activate_user(:authenticator_2fa, @user)
      controller.prepare_for_two_factor_authentication(@user)
    end

    describe "GET show" do
      it "returns totp as the two_factor_method" do
        get :show

        expect(response).to be_successful
        expect(inertia.props[:two_factor_method]).to eq("totp")
      end
    end

    describe "POST create with TOTP code" do
      it "signs in with a valid TOTP code" do
        code = totp_credential.otp_code

        post :create, params: { token: code, user_id: @user.encrypted_external_id }

        expect(flash[:notice]).to eq "Successfully logged in!"
        expect(response).to redirect_to(controller.send(:login_path_for, @user))
      end

      it "rejects an invalid TOTP code" do
        post :create, params: { token: "invalid", user_id: @user.encrypted_external_id }

        expect(flash[:warning]).to eq "Invalid token, please try again."
        expect(response).to redirect_to(two_factor_authentication_path)
      end

      it "does not accept email OTP codes when TOTP is the method" do
        email_code = @user.otp_code

        post :create, params: { token: email_code, user_id: @user.encrypted_external_id }

        expect(response).to redirect_to(two_factor_authentication_path)
        expect(flash[:warning]).to eq("Invalid token, please try again.")
      end

      it "does not accept recovery codes when method is totp" do
        recovery_codes = totp_credential.generate_recovery_codes

        post :create, params: { token: recovery_codes.first, user_id: @user.encrypted_external_id }

        expect(flash[:warning]).to eq "Invalid token, please try again."
      end
    end

    describe "POST create with recovery code" do
      before do
        controller.two_factor_auth_method = "recovery"
      end

      let(:recovery_codes) { totp_credential.generate_recovery_codes }

      it "signs in with a valid recovery code" do
        code = recovery_codes.first

        post :create, params: { token: code, user_id: @user.encrypted_external_id }

        expect(flash[:notice]).to eq "Successfully logged in!"
        expect(response).to redirect_to(controller.send(:login_path_for, @user))
        expect(totp_credential.reload.recovery_codes.size).to eq(9)
      end

      it "rejects an already-used recovery code" do
        code = recovery_codes.first
        totp_credential.redeem_recovery_code(code)

        post :create, params: { token: code, user_id: @user.encrypted_external_id }

        expect(flash[:warning]).to eq "Invalid token, please try again."
      end

      it "does not accept TOTP codes when method is recovery" do
        totp_credential.generate_recovery_codes
        code = totp_credential.otp_code

        post :create, params: { token: code, user_id: @user.encrypted_external_id }

        expect(flash[:warning]).to eq "Invalid token, please try again."
      end
    end
  end
end
