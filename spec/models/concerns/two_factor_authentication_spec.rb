# frozen_string_literal: true

require "spec_helper"

describe TwoFactorAuthentication do
  before do
    @user = create(:user)
  end

  describe "#otp_secret_key" do
    it "sets otp_secret_key for a new user" do
      expect(@user.otp_secret_key.length).to eq 32
    end
  end

  describe ".find_by_encrypted_external_id" do
    it "find the user" do
      expect(User.find_by_encrypted_external_id(@user.encrypted_external_id)).to eq @user
    end
  end

  describe "#encrypted_external_id" do
    it "returns the encrypted external id" do
      expect(@user.encrypted_external_id).to eq ObfuscateIds.encrypt(@user.external_id)
    end
  end

  describe "#two_factor_authentication_cookie_key" do
    it "returns two factor authentication cookie key" do
      encrypted_id_sha = Digest::SHA256.hexdigest(@user.encrypted_external_id)[0..12]

      expect(@user.two_factor_authentication_cookie_key).to eq "_gumroad_two_factor_#{encrypted_id_sha}"
    end
  end

  describe "#send_authentication_token!" do
    before do
      EmailRouterFallbackService.clear(user: @user)
    end

    it "enqueues authentication token email" do
      expect do
        @user.send_authentication_token!
      end.to have_enqueued_mail(TwoFactorAuthenticationMailer, :authentication_token).with(@user.id, email_provider: nil)
    end

    context "when feature flag is active and email was recently sent" do
      before do
        Feature.activate(:resend_fallback_for_auth_emails)
        EmailRouterFallbackService.record_email_sent(user: @user)
      end

      it "enqueues authentication token email with Resend provider" do
        expect do
          @user.send_authentication_token!
        end.to have_enqueued_mail(TwoFactorAuthenticationMailer, :authentication_token).with(@user.id, email_provider: MailerInfo::EMAIL_PROVIDER_RESEND)
      end
    end

    context "when feature flag is inactive" do
      before do
        Feature.deactivate(:resend_fallback_for_auth_emails)
        EmailRouterFallbackService.record_email_sent(user: @user)
      end

      it "enqueues authentication token email with nil provider" do
        expect do
          @user.send_authentication_token!
        end.to have_enqueued_mail(TwoFactorAuthenticationMailer, :authentication_token).with(@user.id, email_provider: nil)
      end
    end
  end

  describe "#add_two_factor_authenticated_ip!" do
    it "adds the two factor authenticated IP to redis" do
      @user.add_two_factor_authenticated_ip!("127.0.0.1")

      expect(@user.two_factor_auth_redis_namespace.get("auth_ip_#{@user.id}_127.0.0.1")).to eq "true"
    end
  end

  describe "#token_authenticated?" do
    describe "token validity" do
      context "when token is more than 10 minutes old" do
        before do
          travel_to(11.minutes.ago) do
            @token = @user.otp_code
          end
        end

        it "returns false" do
          expect(@user.token_authenticated?(@token)).to eq false
        end
      end

      context "when token is less than 10 minutes old" do
        before do
          travel_to(9.minutes.ago) do
            @token = @user.otp_code
          end
        end

        it "returns true" do
          expect(@user.token_authenticated?(@token)).to eq true
        end
      end
    end

    describe "default authentication token" do
      before do
        allow(@user).to receive(:authenticate_otp).and_return(false)
      end

      context "when Rails environment is not production" do
        it "returns true" do
          expect(@user.token_authenticated?("000000")).to eq true
        end
      end

      context "when Rails environment is production" do
        before do
          allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
        end

        it "returns false" do
          expect(@user.token_authenticated?("000000")).to eq false
        end
      end
    end
  end

  describe "#has_logged_in_from_ip_before?" do
    before do
      @user.add_two_factor_authenticated_ip!("127.0.0.2")
    end

    context "when the user has logged in from the IP" do
      it "returns true" do
        expect(@user.has_logged_in_from_ip_before?("127.0.0.2")).to eq true
      end
    end

    context "when the user has not logged in from the IP" do
      it "returns false" do
        expect(@user.has_logged_in_from_ip_before?("127.0.0.3")).to eq false
      end
    end
  end

  describe "#two_factor_auth_redis_namespace" do
    it "returns the redis namespace for two factor authentication" do
      redis_namespace = @user.two_factor_auth_redis_namespace

      expect(redis_namespace).to be_a Redis::Namespace
      expect(redis_namespace.namespace).to eq :two_factor_auth_redis_namespace
    end
  end
end
