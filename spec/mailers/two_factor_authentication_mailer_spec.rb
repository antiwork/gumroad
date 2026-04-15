# frozen_string_literal: true

require "spec_helper"

describe TwoFactorAuthenticationMailer do
  let(:user) { create :user }

  describe "#authentication_token" do
    before do
      @mail = TwoFactorAuthenticationMailer.authentication_token(user.id)
    end

    it "has has all required information" do
      expect(@mail.to).to eq [user.email]
      expect(@mail.subject).to include("Your authentication token is #{user.otp_code}")
      expect(@mail.body).to include(user.otp_code)
      expect(@mail.body).to have_link("Login", href: verify_two_factor_authentication_url(token: user.otp_code, user_id: user.encrypted_external_id, format: :html))
      expect(@mail.body).to include("This authentication token and login link will expire in 10 minutes.")
    end

    context "when email_provider is nil (default)" do
      before do
        @mail = TwoFactorAuthenticationMailer.authentication_token(user.id, email_provider: nil)
      end

      it "uses SendGrid delivery method" do
        expect(@mail.delivery_method.settings[:address]).to eq SENDGRID_SMTP_ADDRESS
      end
    end

    context "when email_provider is Resend" do
      before do
        @mail = TwoFactorAuthenticationMailer.authentication_token(user.id, email_provider: MailerInfo::EMAIL_PROVIDER_RESEND)
      end

      it "uses Resend delivery method" do
        expect(@mail.delivery_method.settings[:address]).to eq RESEND_SMTP_ADDRESS
      end
    end
  end
end
