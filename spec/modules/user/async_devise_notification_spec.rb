# frozen_string_literal: true

require "spec_helper"

describe User::AsyncDeviseNotification do
  include ActiveJob::TestHelper

  let(:user) { create(:user) }

  shared_examples_for "an email sending method" do |devise_email_method, devise_email_name|
    describe "##{devise_email_method}" do
      it "queues the #{devise_email_name} email in the background" do
        expect do
          user.public_send(devise_email_method)
        end.to(have_enqueued_mail(UserSignupMailer, devise_email_name))
      end

      it "actually sends the email" do
        perform_enqueued_jobs do
          expect do
            user.public_send(devise_email_method)
          end.to change { ActionMailer::Base.deliveries.count }.by(1)
        end
      end
    end
  end

  include_examples "an email sending method", "send_confirmation_instructions", "confirmation_instructions"
  include_examples "an email sending method", "send_reset_password_instructions", "reset_password_instructions"

  describe "Resend fallback for password reset" do
    before do
      ResendFallbackTracker.clear(email_type: :password_reset, user_id: user.id)
    end

    it "records email sent when sending reset_password_instructions" do
      expect(ResendFallbackTracker).to receive(:record_email_sent).with(email_type: :password_reset, user_id: user.id)

      user.send_reset_password_instructions
    end

    it "does not record email sent for confirmation_instructions" do
      expect(ResendFallbackTracker).not_to receive(:record_email_sent)

      user.send_confirmation_instructions
    end

    context "when feature flag is active and email was recently sent" do
      before do
        Feature.activate(:resend_fallback_for_auth_emails)
        ResendFallbackTracker.record_email_sent(email_type: :password_reset, user_id: user.id)
      end

      it "uses Resend delivery method for password reset" do
        perform_enqueued_jobs do
          user.send_reset_password_instructions

          mail = ActionMailer::Base.deliveries.last
          expect(mail.delivery_method.settings[:address]).to eq RESEND_SMTP_ADDRESS
        end
      end
    end

    context "when feature flag is inactive" do
      before do
        Feature.deactivate(:resend_fallback_for_auth_emails)
        ResendFallbackTracker.record_email_sent(email_type: :password_reset, user_id: user.id)
      end

      it "uses SendGrid delivery method for password reset" do
        perform_enqueued_jobs do
          user.send_reset_password_instructions

          mail = ActionMailer::Base.deliveries.last
          expect(mail.delivery_method.settings[:address]).to eq SENDGRID_SMTP_ADDRESS
        end
      end
    end
  end
end


