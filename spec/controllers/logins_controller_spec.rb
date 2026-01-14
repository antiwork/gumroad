# frozen_string_literal: true

require "spec_helper"
require "shared_examples/merge_guest_cart_with_user_cart"
require "inertia_rails/rspec"

describe LoginsController, type: :controller, inertia: true do
  render_views

  before :each do
    request.env["devise.mapping"] = Devise.mappings[:user]
  end

  describe "GET 'new'" do
    it "renders successfully" do
      get :new

      expect(response).to be_successful
      expect(inertia.component).to eq("Logins/New")
      expect(inertia.props[:current_user]).to be_nil
      expect(inertia.props[:title]).to eq("Log In")
      expect(inertia.props[:email]).to be_nil
      expect(inertia.props[:application_name]).to be_nil
      expect(inertia.props[:recaptcha_site_key]).to eq(GlobalConfig.get("RECAPTCHA_LOGIN_SITE_KEY"))
    end

    context "with an email in the query parameters" do
      it "renders successfully" do
        get :new, params: { email: "test@example.com" }

        expect(response).to be_successful
        expect(inertia.component).to eq("Logins/New")
        expect(inertia.props[:email]).to eq("test@example.com")
      end
    end

    context "with an email in the next parameter" do
      it "renders successfully" do
        get :new, params: { next: settings_team_invitations_path(email: "test@example.com", format: :json) }

        expect(response).to be_successful
        expect(inertia.component).to eq("Logins/New")
        expect(inertia.props[:email]).to eq("test@example.com")
      end
    end

    it "redirects with the 'next' value from the referrer if not supplied in the params" do
      @request.env["HTTP_REFERER"] = products_path
      get :new

      expect(response).to redirect_to(login_path(next: products_path))
    end

    it "does not redirect with the 'next' value from the referrer if it equals to the root route" do
      @request.env["HTTP_REFERER"] = root_path
      get :new

      expect(response).to be_successful
    end

    describe "OAuth login" do
      before do
        @oauth_application = create(:oauth_application_valid)
        @next_url = oauth_authorization_path(client_id: @oauth_application.uid, redirect_uri: @oauth_application.redirect_uri, scope: "edit_products")
      end

      it "renders successfully" do
        get :new, params: { next: @next_url }
        expect(response).to be_successful
        expect(inertia.component).to eq("Logins/New")
        expect(inertia.props[:application_name]).to eq(@oauth_application.name)
      end

      it "responds with bad request if format is json" do
        get :new, params: { next: @next_url }, format: :json
        expect(response).to be_a_bad_request
      end

      it "sets the application" do
        get :new, params: { next: @next_url }

        expect(assigns[:application]).to eq @oauth_application
      end

      it "sets noindex header when next param starts with /oauth/authorize" do
        get :new, params: { next: "/oauth/authorize?client_id=123" }
        expect(response.headers["X-Robots-Tag"]).to eq "noindex"
      end

      it "does not set noindex header for regular login" do
        get :new
        expect(response.headers["X-Robots-Tag"]).to be_nil
      end
    end
  end

  describe "POST create" do
    before do
      @user = create(:user, password: "password")
    end

    it "logs in if user already exists" do
      post "create", params: { user: { login_identifier: @user.email, password: "password" } }
      expect(response).to redirect_to(dashboard_path)
    end

    it "shows proper error if password is incorrect" do
      post "create", params: { user: { login_identifier: @user.email, password: "hunter2" } }
      expect(response).to redirect_to(login_path)
      expect(flash[:warning]).to eq("Please try another password. The one you entered was incorrect.")
    end

    it "shows proper error if email doesn't exist" do
      post "create", params: { user: { login_identifier: "hithere@gumroaddddd.com", password: "password" } }
      expect(response).to redirect_to(login_path)
      expect(flash[:warning]).to eq("An account does not exist with that email.")
    end

    it "returns an error with no params" do
      post "create"
      expect(response).to redirect_to(login_path)
      expect(flash[:warning]).to eq("An account does not exist with that email.")
    end

    it "logs in if user already exists and redirects to next if present" do
      post "create", params: { user: { login_identifier: @user.email, password: "password" }, next: "/about" }
      expect(response).to redirect_to("/about")
    end

    it "does not redirect to absolute url" do
      post "create", params: { user: { login_identifier: @user.email, password: "password" }, next: "https://elite.haxor.net/home?steal=everything#yes" }
      expect(response).to redirect_to("/home?steal=everything")
    end

    it "redirects back to subdomain URL" do
      stub_const("ROOT_DOMAIN", "test.gumroad.com")
      post "create", params: { user: { login_identifier: @user.email, password: "password" }, next: "https://username.test.gumroad.com" }

      expect(response).to redirect_to("https://username.test.gumroad.com")
    end

    it "disallows logging in if the user has been deleted" do
      @user.deleted_at = Time.current
      @user.save!

      post "create", params: { user: { login_identifier: @user.email, password: "password" } }

      expect(response).to redirect_to(login_path)
      expect(flash[:warning]).to eq("You cannot log in because your account was permanently deleted. Please sign up for a new account to start selling!")
    end

    it "does not log in a user when reCAPTCHA is not completed" do
      allow(controller).to receive(:valid_recaptcha_response?).and_return(false)

      post :create, params: { user: { login_identifier: @user.email, password: "password" } }

      expect(response).to redirect_to(login_path)
      expect(flash[:warning]).to eq "Sorry, we could not verify the CAPTCHA. Please try again."
      expect(controller.user_signed_in?).to be(false)
    end

    it "logs in a user when reCAPTCHA is completed correctly" do
      post :create, params: { user: { login_identifier: @user.email, password: "password" } }

      expect(response).to redirect_to(dashboard_path)
      expect(controller.user_signed_in?).to be(true)
    end

    it "logs in a user when reCAPTCHA site key is not set in development environment" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
      allow(GlobalConfig).to receive(:get).with("RECAPTCHA_LOGIN_SITE_KEY").and_return(nil)

      post :create, params: { user: { login_identifier: @user.email, password: "password" } }

      expect(response).to redirect_to(dashboard_path)
      expect(controller.user_signed_in?).to be(true)
    end

    it "does not log in a user when reCAPTCHA site key is not set in production environment" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
      allow(GlobalConfig).to receive(:get).with("RECAPTCHA_LOGIN_SITE_KEY").and_return(nil)
      allow_any_instance_of(LoginsController).to receive(:valid_recaptcha_response?).and_return(false)

      post :create, params: { user: { login_identifier: @user.email, password: "password" } }

      expect(response).to redirect_to(login_path)
      expect(controller.user_signed_in?).to be(false)
    end

    it "sets the 'Remember Me' cookie" do
      post :create, params: { user: { login_identifier: @user.email, password: "password" } }

      expect(response.cookies["remember_user_token"]).to be_present
    end

    describe "user suspended" do
      before do
        @bad_user = create(:user)
      end

      describe "for ToS violation" do
        before do
          @product = create(:product, user: @user)
          @user.flag_for_tos_violation(author_id: @bad_user.id, product_id: @product.id)
          @user.suspend_for_tos_violation(author_id: @bad_user.id)
        end

        it "is allowed to login" do
          post :create, params: { user: { login_identifier: @user.email, password: "password" } }
          expect(response).to redirect_to(dashboard_path)
        end
      end

      it "does not log in a user who is suspended for fraud" do
        user = create(:user, password: "password", user_risk_state: "suspended_for_fraud")

        post :create, params: { user: { login_identifier: user.email, password: "password" } }

        expect(flash[:warning]).to eq("You can't perform this action because your account has been suspended.")
        expect(controller.user_signed_in?).to be(false)
      end
    end

    describe "referrer present" do
      describe "referrer is root" do
        before do
          @request.env["HTTP_REFERER"] = root_path
        end

        describe "buyer" do
          before do
            @user = create(:user, password: "password")
            @purchase = create(:purchase, purchaser: @user)
          end

          it "redirects to library" do
            post :create, params: { user: { login_identifier: @user.email, password: "password" } }
            expect(response).to redirect_to(library_path)
          end
        end

        describe "seller" do
          before do
            @user = create(:user, password: "password")
          end

          it "redirects to dashboard" do
            post :create, params: { user: { login_identifier: @user.email, password: "password" } }
            expect(response).to redirect_to(dashboard_path)
          end
        end
      end

      describe "referrer is not root" do
        before do
          @product = create(:product)
          @request.env["HTTP_REFERER"] = short_link_path(@product)
        end

        it "redirects back to the last location" do
          post :create, params: { user: { login_identifier: @user.email, password: "password" } }
          expect(response).to redirect_to(short_link_path(@product))
        end
      end
    end

    describe "OAuth login" do
      before do
        oauth_application = create(:oauth_application_valid)
        @next_url = oauth_authorization_path(client_id: oauth_application.uid, redirect_uri: oauth_application.redirect_uri, scope: "edit_products")
      end

      it "redirects to the OAuth authorization path after successful login" do
        post "create", params: { user: { login_identifier: @user.email, password: "password" }, next: @next_url }

        expect(response).to redirect_to(CGI.unescape(@next_url))
      end
    end

    describe "two factor authentication" do
      before do
        @user.two_factor_authentication_enabled = true
        @user.save!
      end

      it "sets the user_id in session and redirects for two factor authentication" do
        post "create", params: { user: { login_identifier: @user.email, password: "password" }, next: settings_main_path }

        expect(session[:verify_two_factor_auth_for]).to eq @user.id
        expect(response).to redirect_to(two_factor_authentication_path(next: settings_main_path))
        expect(controller.user_signed_in?).to eq false
      end
    end

    it_behaves_like "merge guest cart with user cart" do
      let(:user) { @user }
      let(:call_action) { post "create", params: { user: { login_identifier: user.email, password: "password" } } }
      let(:expected_redirect_location) { dashboard_path }
    end
  end

  describe "GET destroy" do
    let(:user) { create(:user) }

    before do
      sign_in user
    end

    it "clears cookies on sign out" do
      cookies["last_viewed_dashboard"] = "sales"

      get :destroy

      # Ensure that the server instructs the client to clear the cookie
      expect(response.cookies.key?("last_viewed_dashboard")).to eq(true)
      expect(response.cookies["last_viewed_dashboard"]).to be_nil
    end

    context "when impersonating" do
      let(:admin) { create(:admin_user) }

      before do
        sign_in admin
        controller.impersonate_user(user)
      end

      it "resets impersonated user" do
        expect(controller.impersonated_user).to eq(user)

        get :destroy

        expect(controller.impersonated_user).to be_nil
        expect($redis.get(RedisKey.impersonated_user(admin.id))).to be_nil
      end
    end
  end

  describe "DELETE destroy" do
    let(:user) { create(:user) }

    before do
      sign_in user
    end

    it "signs out the user and redirects to root path with notice" do
      delete :destroy

      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to eq("Signed out successfully.")
      expect(controller.user_signed_in?).to be(false)
    end

    it "clears cookies on sign out" do
      cookies["last_viewed_dashboard"] = "sales"

      delete :destroy

      expect(response.cookies.key?("last_viewed_dashboard")).to eq(true)
      expect(response.cookies["last_viewed_dashboard"]).to be_nil
    end

    context "when impersonating" do
      let(:admin) { create(:admin_user) }

      before do
        sign_in admin
        controller.impersonate_user(user)
      end

      it "resets impersonated user" do
        expect(controller.impersonated_user).to eq(user)

        delete :destroy

        expect(controller.impersonated_user).to be_nil
        expect($redis.get(RedisKey.impersonated_user(admin.id))).to be_nil
      end
    end
  end
end
