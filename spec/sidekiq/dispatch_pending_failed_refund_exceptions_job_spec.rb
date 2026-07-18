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
  end
end
