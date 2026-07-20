# frozen_string_literal: true

require "spec_helper"

describe NotifyFailedRefundExceptionJob do
  describe "#perform" do
    let(:refund) { create(:refund, processor_refund_id: "re_failed_notification") }
    let(:failed_refund_exception) { create(:failed_refund_exception, refund:, balance_reversed: true) }

    it "reports to Sentry only (no email) and marks the durable record sent" do
      expect(InternalNotificationMailer).not_to receive(:notify)
      expect(ErrorNotifier).to receive(:notify).with(
        a_string_including(
          "buyer was NOT made whole",
          "Exception ##{failed_refund_exception.id} is assigned to #{failed_refund_exception.owner}",
          refund.processor_refund_id
        ),
        context: hash_including(
          failed_refund_exception_id: failed_refund_exception.id,
          refund_id: failed_refund_exception.refund_id,
          balance_reversed: true
        )
      )

      freeze_time do
        described_class.new.perform(failed_refund_exception.id)

        expect(failed_refund_exception.reload).to have_attributes(
          notification_failures: 0,
          notification_sent_at: Time.current
        )
      end
    end

    it "carries the persisted room in the Sentry context for routing/filtering" do
      failed_refund_exception.update!(owner: "refund-taskforce", notification_room: "risk")

      expect(ErrorNotifier).to receive(:notify)
        .with(anything, context: hash_including(notification_room: "risk", owner: "refund-taskforce"))

      described_class.new.perform(failed_refund_exception.id)
    end

    it "states that the retained processor fee was not reversed" do
      refund.update!(retained_fee_cents: 87)

      expect(ErrorNotifier).to receive(:notify).with(
        a_string_including("87-cent processor fee retained via a separate credit was NOT reversed"),
        context: hash_including(retained_fee_cents: 87)
      )

      described_class.new.perform(failed_refund_exception.id)
    end

    it "does not invent a reason when no balance reversal was recorded" do
      failed_refund_exception.update!(balance_reversed: false)

      expect(ErrorNotifier).to receive(:notify).with(
        satisfy do |message|
          message.include?("Nothing was reversed automatically") &&
            message.include?("Review the exception before changing") &&
            !message.include?("because money also moved outside")
        end,
        context: anything
      )

      described_class.new.perform(failed_refund_exception.id)
    end

    it "stops attempting reporting once the failure cap is reached" do
      failed_refund_exception.update!(notification_failures: FailedRefundException::MAX_NOTIFICATION_FAILURES)
      expect(ErrorNotifier).not_to receive(:notify)

      described_class.new.perform(failed_refund_exception.id)

      expect(failed_refund_exception.reload.notification_failures)
        .to eq(FailedRefundException::MAX_NOTIFICATION_FAILURES)
    end

    it "leaves the record pending when the Sentry report fails so Sidekiq can retry" do
      expect(ErrorNotifier).to receive(:notify).and_raise("sentry unavailable")

      expect { described_class.new.perform(failed_refund_exception.id) }
        .to raise_error("sentry unavailable")

      expect(failed_refund_exception.reload).to have_attributes(
        notification_failures: 1,
        notification_sent_at: nil
      )
    end

    it "does not report again after delivery is recorded" do
      failed_refund_exception.update!(notification_sent_at: Time.current)
      expect(ErrorNotifier).not_to receive(:notify)

      described_class.new.perform(failed_refund_exception.id)

      expect(failed_refund_exception.reload.notification_failures).to eq(0)
    end

    it "does not report an exception that was resolved before the job ran" do
      failed_refund_exception.resolve!(resolution: "Resolved before notification delivery")
      expect(ErrorNotifier).not_to receive(:notify)

      described_class.new.perform(failed_refund_exception.id)

      expect(failed_refund_exception.reload.notification_failures).to eq(0)
    end

    it "never sends email under any circumstances" do
      expect(InternalNotificationMailer).not_to receive(:notify)
      allow(ErrorNotifier).to receive(:notify)

      described_class.new.perform(failed_refund_exception.id)
    end
  end
end
