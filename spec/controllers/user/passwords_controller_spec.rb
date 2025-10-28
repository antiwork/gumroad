# frozen_string_literal: true

require "spec_helper"

describe User::PasswordsController do
  before do
    request.env["devise.mapping"] = Devise.mappings[:user]
    @user = create(:user)
  end

  describe "#new" do
    it "404s" do
      expect { get :new }.to raise_error(ActionController::RoutingError)
    end
  end

  describe "#create" do
    it "sends an email to the user" do
      post(:create, params: { user: { email: @user.email } })
      expect(response).to be_successful
    end

    it "returns a json error if email is blank even if matching user exists" do
      create(:user, email: "", provider: :twitter)
      post(:create, params: { user: { email: "" } })
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error_message"]).to eq "An account does not exist with that email."
    end

    it "returns a json error if email is not valid" do
      post(:create, params: { user: { email: "this is no sort of valid email address" } })
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error_message"]).to eq "An account does not exist with that email."
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
        expect(flash[:alert]).to eq "That reset password token doesn't look valid (or may have expired)."
        expect(response).to redirect_to root_url
      end
    end
  end

  describe "#update" do
    it "logs in after successful pw reset" do
      post :update, params: { user: { password: "password_new", password_confirmation: "password_new", reset_password_token: @user.send_reset_password_instructions } }

      expect(@user.reload.valid_password?("password_new")).to be(true)

      expect(flash[:notice]).to eq "Your password has been reset, and you're now logged in."
      expect(response).to be_successful
    end

    it "invalidates all active sessions after successful password reset" do
      expect_any_instance_of(User).to receive(:invalidate_active_sessions!).and_call_original

      post :update, params: { user: { password: "password_new", password_confirmation: "password_new", reset_password_token: @user.send_reset_password_instructions } }
    end

    describe "should fail when there are errors" do
      let(:old_password) { @user.password }

      it "shows error after unsuccessful pw reset" do
        @user.send_reset_password_instructions
        post :update, params: { user: { password: "password_new", password_confirmation: "password_no", reset_password_token: @user.send_reset_password_instructions } }

        expect(@user.password).to eq old_password
        expect(response.parsed_body).to eq({ error_message: "Those two passwords didn't match." }.as_json)
      end

      context "when specifying a compromised password", :vcr do
        it "fails with an error" do
          with_real_pwned_password_check do
            post :update, params: { user: { password: "password", password_confirmation: "password", reset_password_token: @user.send_reset_password_instructions } }
          end

          expect(response.parsed_body).to eq({ error_message: "Password has previously appeared in a data breach as per haveibeenpwned.com and should never be used. Please choose something harder to guess." }.as_json)
        end
      end
    end
  end
end
