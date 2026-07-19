# frozen_string_literal: true

require "spec_helper"

describe DispatchPendingFailedRefundExceptionsJob do
  describe "#perform" do
    it "enqueues each pending notification and skips sent or resolved exceptions" do
      pending_exception = create(:failed_refund_exception)
      create(:failed_refund_exception, notification_sent_at: Time.current)
      create(:failed_refund_exception, state: "resolved", resolved_at: Time.current)

      described_class.new.perform

      expect(NotifyFailedRefundExceptionJob).to have_enqueued_sidekiq_job(pending_exception.id)
      expect(NotifyFailedRefundExceptionJob.jobs.size).to eq(1)
    end

    it "escalates an exception whose delivery failures are exhausted instead of re-enqueuing it" do
      exhausted = create(
        :failed_refund_exception,
        notification_failures: FailedRefundException::MAX_NOTIFICATION_FAILURES
      )

      expect(ErrorNotifier).to receive(:notify).with(
        a_string_including("escalated", "Notification delivery failed"),
        context: hash_including(
          failed_refund_exception_id: exhausted.id,
          notification_failures: FailedRefundException::MAX_NOTIFICATION_FAILURES
        )
      )

      described_class.new.perform

      expect(NotifyFailedRefundExceptionJob.jobs.size).to eq(0)
      expect(exhausted.reload).to have_attributes(
        state: "escalated",
        resolution: a_string_including("Notification delivery failed")
      )
    end

    it "escalates a pending exception past its response deadline" do
      overdue = create(
        :failed_refund_exception,
        due_at: 1.hour.ago,
        notification_sent_at: 25.hours.ago
      )

      expect(ErrorNotifier).to receive(:notify).with(
        a_string_including("Response SLA breached"),
        context: hash_including(failed_refund_exception_id: overdue.id)
      )

      described_class.new.perform

      expect(overdue.reload).to have_attributes(
        state: "escalated",
        resolution: a_string_including("Response SLA breached")
      )
    end

    it "still escalates when the escalation email cannot be delivered" do
      exhausted = create(
        :failed_refund_exception,
        notification_failures: FailedRefundException::MAX_NOTIFICATION_FAILURES
      )
      expect(ErrorNotifier).to receive(:notify)
      mailer = double("mailer")
      expect(InternalNotificationMailer).to receive(:notify).and_return(mailer)
      expect(mailer).to receive(:deliver_now).and_raise("mail unavailable")

      expect { described_class.new.perform }.not_to raise_error

      expect(exhausted.reload.state).to eq("escalated")
    end

    it "does not escalate the same exception twice" do
      create(
        :failed_refund_exception,
        notification_failures: FailedRefundException::MAX_NOTIFICATION_FAILURES,
        due_at: 1.hour.ago
      )
      expect(ErrorNotifier).to receive(:notify).once

      described_class.new.perform
      described_class.new.perform
    end

    describe "digest flood protection" do
      it "keeps per-row emails and Sentry events at the digest threshold" do
        exceptions = create_list(
          :failed_refund_exception,
          DispatchPendingFailedRefundExceptionsJob::ESCALATION_DIGEST_THRESHOLD,
          due_at: 1.hour.ago,
          notification_sent_at: 25.hours.ago
        )

        expect(ErrorNotifier).to receive(:notify)
          .exactly(exceptions.size).times
          .with(a_string_including("Response SLA breached"), context: anything)
        expect do
          described_class.new.perform
        end.to change { ActionMailer::Base.deliveries.size }.by(exceptions.size)

        exceptions.each do |exception|
          expect(exception.reload).to have_attributes(
            state: "escalated",
            resolution: a_string_including("Response SLA breached")
          )
        end
      end

      it "sends one digest email and one Sentry event when more than the threshold escalate in one run" do
        exceptions = create_list(
          :failed_refund_exception,
          DispatchPendingFailedRefundExceptionsJob::ESCALATION_DIGEST_THRESHOLD + 1,
          due_at: 2.hours.ago,
          notification_sent_at: 25.hours.ago
        )
        total_amount_cents = exceptions.sum { |exception| exception.refund.amount_cents }

        expect(ErrorNotifier).to receive(:notify).once.with(
          a_string_including("#{exceptions.size} failed-refund exceptions escalated"),
          context: hash_including(
            escalated_count: exceptions.size,
            overdue_count: exceptions.size,
            delivery_exhausted_count: 0,
            failed_refund_exception_id_min: exceptions.map(&:id).min,
            failed_refund_exception_id_max: exceptions.map(&:id).max,
            total_refund_amount_cents: total_amount_cents
          )
        )

        expect do
          described_class.new.perform
        end.to change { ActionMailer::Base.deliveries.size }.by(1)

        digest_body = ActionMailer::Base.deliveries.last.body.encoded
        expect(digest_body).to include("#{exceptions.size} failed-refund exceptions escalated")

        exceptions.each do |exception|
          expect(exception.reload).to have_attributes(
            state: "escalated",
            resolution: a_string_including("Response SLA breached")
          )
        end
      end

      it "digests a mixed run of delivery-exhausted and overdue exceptions with per-kind resolutions" do
        exhausted = create_list(
          :failed_refund_exception,
          3,
          notification_failures: FailedRefundException::MAX_NOTIFICATION_FAILURES
        )
        overdue = create_list(
          :failed_refund_exception,
          3,
          due_at: 1.hour.ago,
          notification_sent_at: 25.hours.ago
        )

        expect(ErrorNotifier).to receive(:notify).once.with(
          a_string_including("6 failed-refund exceptions escalated"),
          context: hash_including(
            escalated_count: 6,
            delivery_exhausted_count: 3,
            overdue_count: 3
          )
        )

        expect do
          described_class.new.perform
        end.to change { ActionMailer::Base.deliveries.size }.by(1)

        exhausted.each do |exception|
          expect(exception.reload.resolution).to include("Notification delivery failed")
        end
        overdue.each do |exception|
          expect(exception.reload.resolution).to include("Response SLA breached")
        end
      end

      it "escalates every row even when the digest email cannot be delivered" do
        exceptions = create_list(
          :failed_refund_exception,
          DispatchPendingFailedRefundExceptionsJob::ESCALATION_DIGEST_THRESHOLD + 1,
          due_at: 1.hour.ago,
          notification_sent_at: 25.hours.ago
        )
        expect(ErrorNotifier).to receive(:notify).once
        mailer = double("mailer")
        expect(InternalNotificationMailer).to receive(:notify).and_return(mailer)
        expect(mailer).to receive(:deliver_now).and_raise("mail unavailable")

        expect { described_class.new.perform }.not_to raise_error

        exceptions.each do |exception|
          expect(exception.reload.state).to eq("escalated")
        end
      end
    end
  end
end
