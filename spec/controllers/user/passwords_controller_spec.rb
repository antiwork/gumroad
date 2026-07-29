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
    end

    it "sets the page title" do
      get :new

      expect(controller.send(:page_title)).to eq("Forgot password")
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

    # Accounts whose stored address carries an invisible character are the ones most likely to need
    # a reset, because they never received a confirmation email in the first place. The stored
    # address holds the character while the person types the clean version, so looking up only one
    # form would tell them no account exists with the address they are looking straight at.
    context "when the stored address carries an invisible character" do
      before { @user.update_column(:email, "\u200Fbuyer@example.com") }

      it "still finds the account when the clean address is typed" do
        post(:create, params: { user: { email: "buyer@example.com" } })

        expect(response).to redirect_to(login_url)
        expect(flash[:notice]).to eq("Password reset sent! Please make sure to check your spam folder.")
      end

      it "still finds the account when the address is pasted with the character" do
        post(:create, params: { user: { email: "\u200Fbuyer@example.com" } })

        expect(response).to redirect_to(login_url)
        expect(flash[:notice]).to eq("Password reset sent! Please make sure to check your spam folder.")
      end
    end

    # Two live accounts can hold the two variants of the same-looking address: one signed up
    # before we started refusing hidden characters, the other after. Looking both up in one query
    # would send the reset link to whichever row the database returned first, which can be the
    # other person's account, so the address exactly as submitted has to win.
    context "when separate accounts own the typed and the cleaned address" do
      let!(:clean_owner) { create(:user, email: "buyer@example.com") }
      let!(:hidden_owner) { create(:user).tap { _1.update_column(:email, "\u200Fbuyer@example.com") } }

      it "resets the account holding the hidden character when that form is pasted" do
        post(:create, params: { user: { email: "\u200Fbuyer@example.com" } })

        expect(flash[:notice]).to eq("Password reset sent! Please make sure to check your spam folder.")
        expect(hidden_owner.reload.reset_password_token).to be_present
        expect(clean_owner.reload.reset_password_token).to be_nil
      end

      it "resets the account holding the clean address when the clean form is typed" do
        post(:create, params: { user: { email: "buyer@example.com" } })

        expect(flash[:notice]).to eq("Password reset sent! Please make sure to check your spam folder.")
        expect(clean_owner.reload.reset_password_token).to be_present
        expect(hidden_owner.reload.reset_password_token).to be_nil
      end
    end

    # Same rule where a Unicode space is the invisible character rather than a format character.
    # It is worth covering separately because the two behave differently in the database: a format
    # character is ignorable under utf8mb4_unicode_ci, so `WHERE email = '<RLM>buyer@example.com'`
    # also returns the plain row and the byte-for-byte comparison is what tells them apart. A
    # Unicode space is not ignorable, so each row is only returned by matching itself. Both routes
    # have to send the link to the account that owns the address as submitted, and without this
    # context only the first of the two shapes is actually exercised.
    context "when separate accounts own a no-break-space address and the cleaned address" do
      let!(:clean_owner) { create(:user, email: "buyer@example.com") }
      let!(:hidden_owner) { create(:user).tap { _1.update_column(:email, "buyer\u00A0@example.com") } }

      it "resets the account holding the no-break space when that form is pasted" do
        post(:create, params: { user: { email: "buyer\u00A0@example.com" } })

        expect(flash[:notice]).to eq("Password reset sent! Please make sure to check your spam folder.")
        expect(hidden_owner.reload.reset_password_token).to be_present
        expect(clean_owner.reload.reset_password_token).to be_nil
      end

      it "resets the account holding the clean address when the clean form is typed" do
        post(:create, params: { user: { email: "buyer@example.com" } })

        expect(flash[:notice]).to eq("Password reset sent! Please make sure to check your spam folder.")
        expect(clean_owner.reload.reset_password_token).to be_present
        expect(hidden_owner.reload.reset_password_token).to be_nil
      end
    end

    it "redirects with warning if email is not valid" do
      post(:create, params: { user: { email: "this is no sort of valid email address" } })
      expect(response).to redirect_to(login_url)
      expect(flash[:warning]).to eq("An account does not exist with that email.")
    end

    it "redirects with warning when the user param is missing" do
      post(:create)
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

    context "when the user has email two-factor authentication enabled" do
      before do
        @user = create(:user, skip_enabling_two_factor_authentication: false)
      end

      it "redirects to two-factor authentication instead of signing the user in" do
        token = @user.send_reset_password_instructions

        expect do
          post :update, params: { user: { password: "password_new", password_confirmation: "password_new", reset_password_token: token } }
        end.to have_enqueued_mail(TwoFactorAuthenticationMailer, :authentication_token).with(@user.id, email_provider: nil)

        expect(controller.logged_in_user).to be_nil
        expect(session[:verify_two_factor_auth_for]).to eq(@user.id)
        expect(session[:two_factor_auth_method]).to eq("email")
        expect(flash[:notice]).to eq("Your password has been reset. Please complete two-factor authentication to continue.")
        expect(response).to redirect_to(two_factor_authentication_path(next: root_path))
      end
    end

    context "when the user has authenticator-app two-factor authentication enabled" do
      before do
        @user = create(:user, skip_enabling_two_factor_authentication: false)
        create(:totp_credential, :confirmed, user: @user)
      end

      it "redirects to two-factor authentication and keeps the authenticator method" do
        token = @user.send_reset_password_instructions

        expect do
          post :update, params: { user: { password: "password_new", password_confirmation: "password_new", reset_password_token: token } }
        end.not_to have_enqueued_mail(TwoFactorAuthenticationMailer, :authentication_token)

        expect(controller.logged_in_user).to be_nil
        expect(session[:verify_two_factor_auth_for]).to eq(@user.id)
        expect(session[:two_factor_auth_method]).to eq("totp")
        expect(flash[:notice]).to eq("Your password has been reset. Please complete two-factor authentication to continue.")
        expect(response).to redirect_to(two_factor_authentication_path(next: root_path))
      end
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
