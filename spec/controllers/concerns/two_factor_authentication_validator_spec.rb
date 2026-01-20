# frozen_string_literal: true

require "spec_helper"

describe TwoFactorAuthenticationValidator, type: :controller do
  controller(ApplicationController) do
    before_action :authenticate_user!

    include TwoFactorAuthenticationValidator

    def action
      head :ok
    end
  end

  before do
    routes.draw { get :action, to: "anonymous#action" }
  end

  before do
    @user = create(:user, skip_enabling_two_factor_authentication: false)
    sign_in @user
  end

  describe "#skip_two_factor_authentication?" do
    context "when two factor authentication is disabled for the user" do
      before do
        @user.two_factor_authentication_enabled = false
        @user.save!
      end

      it "returns true" do
        expect(controller.skip_two_factor_authentication?(@user)).to eq true
      end
    end

    context "when a valid two factor cookie is present" do
      before do
        cookie_hash = { @user.two_factor_authentication_cookie_key => "#{@user.id},#{5.minutes.from_now.to_i}" }
        encrypted_cookie_jar = OpenStruct.new({ encrypted: cookie_hash })
        allow(controller).to receive(:cookies).and_return(encrypted_cookie_jar)
      end

      it "returns true" do
        expect(controller.skip_two_factor_authentication?(@user)).to eq true
      end

      it "extends the cookie expiry" do
        expect(controller).to receive(:set_two_factor_auth_cookie).and_call_original

        controller.skip_two_factor_authentication?(@user)
      end
    end

    context "when the user has verified two factor auth from that IP before" do
      before do
        @user.add_two_factor_authenticated_ip!("0.0.0.0")
      end

      it "returns true" do
        expect(controller.skip_two_factor_authentication?(@user)).to eq true
      end
    end
  end

  describe "#set_two_factor_auth_cookie" do
    it "sets the two factor auth cookie" do
      travel_to(Time.current) do
        controller.set_two_factor_auth_cookie(@user)

        expires_at = 2.months.from_now.to_i
        cookie_value = "#{@user.id},#{expires_at}"
        cookies_encrypted = controller.send(:cookies).encrypted

        expect(cookies_encrypted[@user.two_factor_authentication_cookie_key]).to eq cookie_value
      end
    end
  end

  describe "#remember_two_factor_auth" do
    it "invokes #set_two_factor_auth_cookie" do
      expect(controller).to receive(:set_two_factor_auth_cookie).and_call_original

      controller.remember_two_factor_auth
    end

    it "remembers the two factor authenticated IP" do
      expect_any_instance_of(User).to receive(:add_two_factor_authenticated_ip!).with("0.0.0.0").and_call_original

      controller.remember_two_factor_auth
    end
  end

  describe "#valid_two_factor_cookie_present?" do
    context "when valid cookie is present" do
      before do
        cookie_hash = { @user.two_factor_authentication_cookie_key => "#{@user.id},#{5.minutes.from_now.to_i}" }
        encrypted_cookie_jar = OpenStruct.new({ encrypted: cookie_hash })
        allow(controller).to receive(:cookies).and_return(encrypted_cookie_jar)
      end

      it "returns true" do
        expect(controller.send(:valid_two_factor_cookie_present?, @user)).to eq true
      end
    end

    context "when valid cookie is not present" do
      context "when cookie is missing" do
        it "returns false" do
          expect(controller.send(:valid_two_factor_cookie_present?, @user)).to eq false
        end
      end

      context "when the timestamp in cookie is expired" do
        before do
          cookie_hash = { @user.two_factor_authentication_cookie_key => "#{@user.id},#{5.minutes.ago.to_i}" }
          encrypted_cookie_jar = OpenStruct.new({ encrypted: cookie_hash })
          allow(controller).to receive(:cookies).and_return(encrypted_cookie_jar)
        end

        it "returns false" do
          expect(controller.send(:valid_two_factor_cookie_present?, @user)).to eq false
        end
      end
    end
  end

  describe "#prepare_for_two_factor_authentication" do
    it "sets user_id in session" do
      controller.prepare_for_two_factor_authentication(@user)

      expect(session[:verify_two_factor_auth_for]).to eq @user.id
    end

    context "when params[:next] contains 2FA verification URL" do
      before do
        allow(controller).to receive(:params).and_return({ next: verify_two_factor_authentication_path(format: :html) })
      end

      it "doesn't send authentication token" do
        expect do
          controller.prepare_for_two_factor_authentication(@user)
        end.not_to have_enqueued_mail(TwoFactorAuthenticationMailer, :authentication_token).with(@user.id, email_provider: nil)
      end
    end

    context "when params[:next] doesn't contain 2FA verification URL" do
      it "sends authentication token" do
        expect do
          controller.prepare_for_two_factor_authentication(@user)
        end.to have_enqueued_mail(TwoFactorAuthenticationMailer, :authentication_token).with(@user.id, email_provider: nil)
      end
    end
  end

  describe "#user_for_two_factor_authentication" do
    before do
      controller.prepare_for_two_factor_authentication(@user)
    end

    it "gets the user from session" do
      expect(controller.user_for_two_factor_authentication).to eq @user
    end
  end

  describe "#reset_two_factor_auth_login_session" do
    before do
      controller.prepare_for_two_factor_authentication(@user)
    end

    it "removes the user_id from session" do
      controller.reset_two_factor_auth_login_session

      expect(session[:verify_two_factor_auth_for]).to be_nil
    end
  end
end
