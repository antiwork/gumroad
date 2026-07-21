# frozen_string_literal: true

require "spec_helper"

describe RetryTransientEmailFailureJob do
  let(:user) { create(:unconfirmed_user, email: "new-seller@brand-new-domain.com") }
  let(:retry_record) do
    TransientEmailFailureRetry.create!(
      email: user.email,
      mail_kind: TransientEmailFailureRetry::SIGNUP_CONFIRMATION,
      attempts: 0,
      retry_in_flight: true,
      last_reason: "i/o timeout"
    )
  end

  describe "#perform" do
    it "removes the address from the bounce and block suppression lists, re-sends the confirmation email, and increments the attempt counter" do
      suppression_manager = instance_double(EmailSuppressionManager)
      expect(EmailSuppressionManager).to receive(:new).with(user.email).and_return(suppression_manager)
      expect(suppression_manager).to receive(:remove_from_lists).with([:bounces, :blocks])

      expect do
        described_class.new.perform(retry_record.id)
      end.to have_enqueued_mail(UserSignupMailer, :confirmation_instructions).with { |record, *| expect(record).to eq(user) }

      retry_record.reload
      expect(retry_record.attempts).to eq(1)
      expect(retry_record.retry_in_flight).to eq(false)
    end

    it "never touches spam report or unsubscribe suppression lists" do
      suppression_manager = instance_double(EmailSuppressionManager)
      allow(EmailSuppressionManager).to receive(:new).and_return(suppression_manager)
      allow(suppression_manager).to receive(:remove_from_lists)

      described_class.new.perform(retry_record.id)

      expect(suppression_manager).to have_received(:remove_from_lists) do |lists|
        expect(lists).not_to include(:spam_reports)
        expect(lists).not_to include(:global_unsubscribes)
      end
    end

    it "skips the resend and clears the in-flight flag when the user has confirmed in the meantime" do
      user.confirm

      expect(EmailSuppressionManager).not_to receive(:new)
      expect do
        described_class.new.perform(retry_record.id)
      end.not_to have_enqueued_mail(UserSignupMailer, :confirmation_instructions)

      retry_record.reload
      expect(retry_record.attempts).to eq(0)
      expect(retry_record.retry_in_flight).to eq(false)
    end

    it "resends to the pending address when the user is re-confirming an email change" do
      confirmed_user = create(:user)
      confirmed_user.update!(unconfirmed_email: "pending@example.com")
      record = TransientEmailFailureRetry.create!(
        email: "pending@example.com",
        mail_kind: TransientEmailFailureRetry::SIGNUP_CONFIRMATION,
        retry_in_flight: true
      )
      suppression_manager = instance_double(EmailSuppressionManager, remove_from_lists: {})
      allow(EmailSuppressionManager).to receive(:new).and_return(suppression_manager)

      expect do
        described_class.new.perform(record.id)
      end.to have_enqueued_mail(UserSignupMailer, :confirmation_instructions).with { |mail_record, *| expect(mail_record).to eq(confirmed_user) }
    end

    it "restores the in-flight claim and re-raises when the resend fails, so a Sidekiq re-run can retry it" do
      retry_record # force lazy creation now — creating the unconfirmed user enqueues its own confirmation email
      suppression_manager = instance_double(EmailSuppressionManager)
      allow(EmailSuppressionManager).to receive(:new).and_return(suppression_manager)
      allow(suppression_manager).to receive(:remove_from_lists).and_raise(StandardError.new("suppression API unavailable"))

      expect do
        expect do
          described_class.new.perform(retry_record.id)
        end.to raise_error(StandardError, "suppression API unavailable")
      end.not_to have_enqueued_mail(UserSignupMailer, :confirmation_instructions)

      retry_record.reload
      expect(retry_record.attempts).to eq(0)
      expect(retry_record.retry_in_flight).to eq(true)

      # The restored claim lets the Sidekiq re-run of this job through the
      # claim guard and complete the send.
      allow(suppression_manager).to receive(:remove_from_lists).and_return({})
      expect do
        described_class.new.perform(retry_record.id)
      end.to have_enqueued_mail(UserSignupMailer, :confirmation_instructions)

      retry_record.reload
      expect(retry_record.attempts).to eq(1)
      expect(retry_record.retry_in_flight).to eq(false)
    end

    it "does not resend when no in-flight claim exists (e.g. a Sidekiq re-run after a completed attempt)" do
      retry_record.update!(retry_in_flight: false, attempts: 1)

      expect(EmailSuppressionManager).not_to receive(:new)
      expect do
        described_class.new.perform(retry_record.id)
      end.not_to have_enqueued_mail(UserSignupMailer, :confirmation_instructions)

      expect(retry_record.reload.attempts).to eq(1)
    end

    it "does nothing when the retry record no longer exists" do
      expect do
        described_class.new.perform(-1)
      end.not_to have_enqueued_mail(UserSignupMailer, :confirmation_instructions)
    end
  end
end
