# frozen_string_literal: true

require "spec_helper"
require "shared_examples/merge_guest_cart_with_user_cart"

describe TwoFactorAuthenticationController do
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

  shared_examples_for "respond with signed_in path for json request" do
    context "when two factor authentication can be skipped" do
      before do
        sign_in @user
        controller.reset_two_factor_auth_login_session
        allow(controller).to receive(:skip_two_factor_authentication?).and_return(true)
      end

      context "when request format is json" do
        it "responds with redirect location" do
          call_action

          expect(response.parsed_body["redirect_location"]).to eq signed_in_user_home(@user)
        end
      end
    end
  end

  shared_examples_for "validate user_id in params for json request" do |action|
    it "renders not found error in json when user_is is invalid" do
      post action, params: { user_id: "invalid" }, format: :json

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["error"]).to eq "Not found"
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

  shared_examples_for "check user in session for json request" do
    it "renders not found error in json when user is not found in session" do
      controller.reset_two_factor_auth_login_session

      call_action

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["error"]).to eq "Not found"
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

  describe "GET new" do # GET /two-factor
    include_examples "redirect to signed_in path for html request" do
      subject(:call_action) { get :new }
    end

    include_examples "check user in session for html request" do
      subject(:call_action) { get :new }
    end

    before do
      controller.prepare_for_two_factor_authentication(@user)
    end

    it "renders HTTP success" do
      get :new

      expect(response).to be_successful
      expect(response).to render_template(:new)
    end

    it "sets @user" do
      get :new

      expect(assigns[:user]).to eq @user
    end
  end

  describe "POST create" do # POST /two-factor.json
    include_examples "validate user_id in params for json request", :create

    include_examples "respond with signed_in path for json request" do
      subject(:call_action) { post :create, format: :json }
    end

    include_examples "check user in session for json request" do
      subject(:call_action) { post :create, format: :json }
    end

    before do
      controller.prepare_for_two_factor_authentication(@user)
    end

    context "when authentication token is valid" do
      include_examples "sign in as user and remember two factor authentication status" do
        subject(:call_action) { post :create, params: { token: @user.otp_code, user_id: @user.encrypted_external_id }, format: :json }
      end

      it "responds with success message" do
        post :create, params: { token: @user.otp_code, user_id: @user.encrypted_external_id }, format: :json

        expect(response).to be_successful
        expect(response.parsed_body).to eq({ "redirect_location" => controller.send(:login_path_for, @user) })
      end

      it_behaves_like "merge guest cart with user cart" do
        let(:user) { @user }
        let(:call_action) { post :create, params: { token: @user.otp_code, user_id: @user.encrypted_external_id }, format: :json }
        let(:expected_redirect_location) { controller.send(:login_path_for, @user) }
        let(:expects_json_response) { true }
      end
    end

    context "when authentication token is invalid" do
      it "responds with failure message" do
        post :create, params: { token: "abcdef", user_id: @user.encrypted_external_id }, format: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body).to eq({ "error_message" => "Invalid token, please try again." })
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

        expect(flash[:alert]).to eq "Invalid token, please try again."
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

  describe "POST resend_authentication_token" do # POST /two-factor/resend_authentication_token.json
    include_examples "validate user_id in params for json request", :resend_authentication_token

    include_examples "respond with signed_in path for json request" do
      subject(:call_action) { post :resend_authentication_token, format: :json }
    end

    include_examples "check user in session for json request" do
      subject(:call_action) { post :resend_authentication_token, format: :json }
    end

    before do
      controller.prepare_for_two_factor_authentication(@user)
    end

    it "resends the authentication token" do
      expect do
        post :resend_authentication_token, params: { user_id: @user.encrypted_external_id }, format: :json
      end.to have_enqueued_mail(TwoFactorAuthenticationMailer, :authentication_token).with(@user.id)

      expect(response).to be_successful
    end
  end
end
