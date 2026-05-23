# frozen_string_literal: true

require "test_helper"

class TwoFactorAuthenticationTest < ActiveSupport::TestCase
  self.described_class = TwoFactorAuthentication



  context_ TwoFactorAuthentication do
    before do
      @user = create(:user)
    end

  context_ "#otp_secret_key" do
  test "sets otp_secret_key for a new user" do
        expect(@user.otp_secret_key.length).to eq 32
      end
    end

  context_ ".find_by_encrypted_external_id" do
  test "find the user" do
        expect(User.find_by_encrypted_external_id(@user.encrypted_external_id)).to eq @user
      end
    end

  context_ "#encrypted_external_id" do
  test "returns the encrypted external id" do
        expect(@user.encrypted_external_id).to eq ObfuscateIds.encrypt(@user.external_id)
      end
    end

  context_ "#two_factor_authentication_cookie_key" do
  test "returns two factor authentication cookie key" do
        encrypted_id_sha = Digest::SHA256.hexdigest(@user.encrypted_external_id)[0..12]

        expect(@user.two_factor_authentication_cookie_key).to eq "_gumroad_two_factor_#{encrypted_id_sha}"
      end
    end

  context_ "#send_authentication_token!" do
      before do
        EmailRouterFallbackService.clear(user: @user)
      end

  test "enqueues authentication token email" do
        expect do
          @user.send_authentication_token!
        end.to have_enqueued_mail(TwoFactorAuthenticationMailer, :authentication_token).with(@user.id, email_provider: nil)
      end

  context_ "when feature flag is active and email was recently sent" do
        before do
          Feature.activate(:resend_fallback_for_auth_emails)
          EmailRouterFallbackService.record_email_sent(user: @user)
        end

  test "enqueues authentication token email with Resend provider" do
          expect do
            @user.send_authentication_token!
          end.to have_enqueued_mail(TwoFactorAuthenticationMailer, :authentication_token).with(@user.id, email_provider: MailerInfo::EMAIL_PROVIDER_RESEND)
        end
      end

  context_ "when feature flag is inactive" do
        before do
          Feature.deactivate(:resend_fallback_for_auth_emails)
          EmailRouterFallbackService.record_email_sent(user: @user)
        end

  test "enqueues authentication token email with nil provider" do
          expect do
            @user.send_authentication_token!
          end.to have_enqueued_mail(TwoFactorAuthenticationMailer, :authentication_token).with(@user.id, email_provider: nil)
        end
      end
    end

  context_ "#add_two_factor_authenticated_ip!" do
  test "adds the two factor authenticated IP to redis" do
        @user.add_two_factor_authenticated_ip!("127.0.0.1")

        expect(@user.two_factor_auth_redis_namespace.get("auth_ip_#{@user.id}_127.0.0.1")).to eq "true"
      end
    end

  context_ "#token_authenticated?" do
  context_ "token validity" do
  context_ "when token is more than 10 minutes old" do
          before do
            travel_to(11.minutes.ago) do
              @token = @user.otp_code
            end
          end

  test "returns false" do
            expect(@user.token_authenticated?(@token)).to eq false
          end
        end

  context_ "when token is less than 10 minutes old" do
          before do
            travel_to(9.minutes.ago) do
              @token = @user.otp_code
            end
          end

  test "returns true" do
            expect(@user.token_authenticated?(@token)).to eq true
          end
        end
      end

  context_ "default authentication token" do
        before do
          allow(@user).to receive(:authenticate_otp).and_return(false)
        end

  context_ "when Rails environment is not production" do
  test "returns true" do
            expect(@user.token_authenticated?("000000")).to eq true
          end
        end

  context_ "when Rails environment is production" do
          before do
            allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
          end

  test "returns false" do
            expect(@user.token_authenticated?("000000")).to eq false
          end
        end
      end
    end

  context_ "#has_logged_in_from_ip_before?" do
      before do
        @user.add_two_factor_authenticated_ip!("127.0.0.2")
      end

  context_ "when the user has logged in from the IP" do
  test "returns true" do
          expect(@user.has_logged_in_from_ip_before?("127.0.0.2")).to eq true
        end
      end

  context_ "when the user has not logged in from the IP" do
  test "returns false" do
          expect(@user.has_logged_in_from_ip_before?("127.0.0.3")).to eq false
        end
      end
    end

  context_ "#totp_enabled?" do
  context_ "when user has no totp credential" do
  test "returns false" do
          expect(@user.totp_enabled?).to be false
        end
      end

  context_ "when user has an unconfirmed totp credential" do
        before { create(:totp_credential, user: @user) }

  test "returns false" do
          expect(@user.totp_enabled?).to be false
        end
      end

  context_ "when user has a confirmed totp credential" do
        before { create(:totp_credential, :confirmed, user: @user) }

  test "returns true" do
          expect(@user.totp_enabled?).to be true
        end
      end
    end

  context_ "#two_factor_auth_redis_namespace" do
  test "returns the redis namespace for two factor authentication" do
        redis_namespace = @user.two_factor_auth_redis_namespace

        expect(redis_namespace).to be_a Redis::Namespace
        expect(redis_namespace.namespace).to eq :two_factor_auth_redis_namespace
      end
    end
  end
end
