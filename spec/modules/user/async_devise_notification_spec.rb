# frozen_string_literal: true

require "spec_helper"

describe User::AsyncDeviseNotification do
  include ActiveJob::TestHelper

  # The methods in this module are private/protected so they aren't tested.
  # Instead, the methods which they affect are tested.

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
end
