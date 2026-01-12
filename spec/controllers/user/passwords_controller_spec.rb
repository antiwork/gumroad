# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe User::PasswordsController, type: :controller, inertia: true do
  render_views

  before do
    request.env["devise.mapping"] = Devise.mappings[:user]
    @user = create(:user)
  end

  describe "#new" do
    it "renders the Inertia password reset page" do
      get :new

      expect(response).to be_successful
      expect(inertia.component).to eq("User/Passwords/New")
      expect(inertia.props[:email]).to be_nil
      expect(inertia.props[:application_name]).to be_nil
      expect(inertia.props[:recaptcha_site_key]).to eq(GlobalConfig.get("RECAPTCHA_LOGIN_SITE_KEY"))
    end

    it "sets the page title" do
      get :new

      expect(assigns[:title]).to eq("Forgot password")
    end
  end

  describe "#create" do
    it "sends an email to the user and redirects with success message" do
      post(:create, params: { user: { email: @user.email } })
      expect(response).to redirect_to(login_url)
      expect(flash[:notice]).to eq("Password reset sent! Please make sure to check your spam folder.")
    end

    it "redirects with warning if email is blank even if matching user exists" do
      create(:user, email: "", provider: :twitter)
      post(:create, params: { user: { email: "" } })
      expect(response).to redirect_to(login_url)
      expect(flash[:warning]).to eq("An account does not exist with that email.")
    end

    it "redirects with warning if email is not valid" do
      post(:create, params: { user: { email: "this is no sort of valid email address" } })
      expect(response).to redirect_to(login_url)
      expect(flash[:warning]).to eq("An account does not exist with that email.")
    end
  end

  describe "#edit" do
    it "shows a form for a valid token" do
      get(:edit, params: { reset_password_token: @user.send_reset_password_instructions })
      expect(response).to be_successful
    end

    describe "should fail when errors" do
      it "shows an error for an invalid token" do
        get :edit, params: { reset_password_token: "invalid" }
        expect(flash[:warning]).to eq "That reset password token doesn't look valid (or may have expired)."
        expect(response).to redirect_to root_path
      end
    end
  end

  describe "#update" do
    it "logs in after successful pw reset" do
      token = @user.send_reset_password_instructions
      post :update, params: { user: { password: "password_new", password_confirmation: "password_new", reset_password_token: token } }

      expect(@user.reload.valid_password?("password_new")).to be(true)

      expect(flash[:notice]).to eq "Your password has been reset, and you're now logged in."
      expect(response).to redirect_to(root_path)
    end

    it "invalidates all active sessions after successful password reset" do
      expect_any_instance_of(User).to receive(:invalidate_active_sessions!).and_call_original

      post :update, params: { user: { password: "password_new", password_confirmation: "password_new", reset_password_token: @user.send_reset_password_instructions } }
    end

    describe "should fail when there are errors" do
      let(:old_password) { @user.password }

      it "shows error after unsuccessful pw reset" do
        token = @user.send_reset_password_instructions
        post :update, params: { user: { password: "password_new", password_confirmation: "password_no", reset_password_token: token } }

        expect(@user.reload.valid_password?(old_password)).to be(true)
        expect(flash[:warning]).to eq "Those two passwords didn't match."
        expect(response).to redirect_to(edit_user_password_path(reset_password_token: token))
      end

      context "when specifying a compromised password", :vcr do
        it "fails with an error" do
          token = @user.send_reset_password_instructions
          with_real_pwned_password_check do
            post :update, params: { user: { password: "password", password_confirmation: "password", reset_password_token: token } }
          end

          expect(flash[:warning]).to eq "Password has previously appeared in a data breach as per haveibeenpwned.com and should never be used. Please choose something harder to guess."
          expect(response).to redirect_to(edit_user_password_path(reset_password_token: token))
        end
      end
    end
  end
end
