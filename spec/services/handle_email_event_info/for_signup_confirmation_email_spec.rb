# frozen_string_literal: true

require "spec_helper"

describe HandleEmailEventInfo::ForSignupConfirmationEmail do
  let(:email) { "new-seller@brand-new-domain.com" }

  def sendgrid_params(event: "bounce", reason: "error dialing remote address: dial tcp 1.2.3.4:25: i/o timeout", mailer_class: "UserSignupMailer", mailer_method: "confirmation_instructions")
    {
      "_json" => [
        {
          "email" => email,
          "event" => event,
          "reason" => reason,
          "mailer_class" => mailer_class,
          "mailer_method" => mailer_method,
          "mailer_args" => "[123]",
        }
      ]
    }
  end

  describe "handling SendGrid events" do
    context "when a signup confirmation email bounces with a transient reason" do
      it "schedules a retry with the first backoff delay and records the attempt state" do
        HandleSendgridEventJob.new.perform(sendgrid_params)

        retry_record = TransientEmailFailureRetry.last
        expect(retry_record.email).to eq(email)
        expect(retry_record.mail_kind).to eq(TransientEmailFailureRetry::SIGNUP_CONFIRMATION)
        expect(retry_record.attempts).to eq(0)
        expect(retry_record.retry_in_flight).to eq(true)
        expect(retry_record.last_reason).to include("i/o timeout")
        expect(RetryTransientEmailFailureJob).to have_enqueued_sidekiq_job(retry_record.id).in(15.minutes)
      end

      it "uses escalating backoff delays for subsequent failures" do
        retry_record = TransientEmailFailureRetry.create!(
          email:, mail_kind: TransientEmailFailureRetry::SIGNUP_CONFIRMATION, attempts: 1
        )

        HandleSendgridEventJob.new.perform(sendgrid_params)

        expect(RetryTransientEmailFailureJob).to have_enqueued_sidekiq_job(retry_record.id).in(2.hours)
      end

      it "does not schedule a duplicate retry while one is already in flight" do
        TransientEmailFailureRetry.create!(
          email:, mail_kind: TransientEmailFailureRetry::SIGNUP_CONFIRMATION, attempts: 1, retry_in_flight: true
        )

        HandleSendgridEventJob.new.perform(sendgrid_params)

        expect(RetryTransientEmailFailureJob.jobs).to be_empty
      end

      it "releases an expired in-flight claim and schedules a retry (lost-job recovery)" do
        retry_record = TransientEmailFailureRetry.create!(
          email:, mail_kind: TransientEmailFailureRetry::SIGNUP_CONFIRMATION, attempts: 1, retry_in_flight: true
        )
        retry_record.update_column(:updated_at, (TransientEmailFailureRetry::CLAIM_EXPIRY + 1.hour).ago)

        HandleSendgridEventJob.new.perform(sendgrid_params)

        expect(retry_record.reload.retry_in_flight).to eq(true)
        expect(RetryTransientEmailFailureJob).to have_enqueued_sidekiq_job(retry_record.id).in(2.hours)
      end

      it "releases the claim and re-raises when enqueuing the retry job fails" do
        allow(RetryTransientEmailFailureJob).to receive(:perform_in).and_raise(RedisClient::CannotConnectError)

        expect do
          HandleSendgridEventJob.new.perform(sendgrid_params)
        end.to raise_error(RedisClient::CannotConnectError)

        retry_record = TransientEmailFailureRetry.last
        expect(retry_record.retry_in_flight).to eq(false)
      end
    end

    context "when a signup confirmation email is blocked with a transient reason" do
      it "schedules a retry" do
        HandleSendgridEventJob.new.perform(sendgrid_params(event: "blocked", reason: "451 Temporary local problem - please try later"))

        expect(RetryTransientEmailFailureJob.jobs.size).to eq(1)
      end
    end

    context "when a signup confirmation email is dropped with a transient reason" do
      it "schedules a retry" do
        HandleSendgridEventJob.new.perform(sendgrid_params(event: "dropped", reason: "452 4.2.2 mailbox full"))

        expect(RetryTransientEmailFailureJob.jobs.size).to eq(1)
      end
    end

    context "when the failure reason is hard" do
      it "does not schedule a retry" do
        HandleSendgridEventJob.new.perform(sendgrid_params(reason: "550 5.1.1 The email account that you tried to reach does not exist"))

        expect(RetryTransientEmailFailureJob.jobs).to be_empty
        expect(TransientEmailFailureRetry.count).to eq(0)
      end
    end

    context "when the failure reason is unknown" do
      it "does not schedule a retry (fail-closed)" do
        HandleSendgridEventJob.new.perform(sendgrid_params(reason: "some novel refusal wording"))

        expect(RetryTransientEmailFailureJob.jobs).to be_empty
      end

      it "does not schedule a retry when the reason is missing" do
        HandleSendgridEventJob.new.perform(sendgrid_params(reason: nil))

        expect(RetryTransientEmailFailureJob.jobs).to be_empty
      end
    end

    context "when the event is a spam report" do
      it "never schedules a retry" do
        HandleSendgridEventJob.new.perform(sendgrid_params(event: "spamreport", reason: "452 4.2.2 mailbox full"))

        expect(RetryTransientEmailFailureJob.jobs).to be_empty
      end
    end

    context "when the retry cap has been reached" do
      it "does not schedule a retry" do
        TransientEmailFailureRetry.create!(
          email:, mail_kind: TransientEmailFailureRetry::SIGNUP_CONFIRMATION,
          attempts: TransientEmailFailureRetry::MAX_ATTEMPTS
        )

        HandleSendgridEventJob.new.perform(sendgrid_params)

        expect(RetryTransientEmailFailureJob.jobs).to be_empty
      end

      it "resets the counter and retries again once the record is stale (per-week cap, not once-ever)" do
        retry_record = TransientEmailFailureRetry.create!(
          email:, mail_kind: TransientEmailFailureRetry::SIGNUP_CONFIRMATION,
          attempts: TransientEmailFailureRetry::MAX_ATTEMPTS
        )
        retry_record.update_column(:updated_at, 8.days.ago)

        HandleSendgridEventJob.new.perform(sendgrid_params)

        expect(retry_record.reload.attempts).to eq(0)
        expect(RetryTransientEmailFailureJob).to have_enqueued_sidekiq_job(retry_record.id).in(15.minutes)
      end
    end

    context "when the event is for a different mailer" do
      it "does not schedule a retry" do
        HandleSendgridEventJob.new.perform(sendgrid_params(mailer_class: "TwoFactorAuthenticationMailer", mailer_method: "authentication_token"))

        expect(RetryTransientEmailFailureJob.jobs).to be_empty
      end
    end
  end
end
