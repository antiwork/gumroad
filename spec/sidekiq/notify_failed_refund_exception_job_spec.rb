# frozen_string_literal: true

require "spec_helper"

describe NotifyFailedRefundExceptionJob do
  describe "#perform" do
    let(:refund) { create(:refund, processor_refund_id: "re_failed_notification") }
    let(:failed_refund_exception) { create(:failed_refund_exception, refund:, balance_reversed: true) }
    let(:mailer) { double("mailer") }

    it "notifies the payments room and marks the durable record sent" do
      expect(InternalNotificationMailer).to receive(:notify).with(
        room_name: "payments",
        sender: "Failed Refund Exception",
        message_text: a_string_including(
          "buyer was NOT made whole",
          "Exception ##{failed_refund_exception.id} is assigned to #{failed_refund_exception.owner}",
          refund.processor_refund_id
        )
      ).and_return(mailer)
      expect(mailer).to receive(:deliver_now)
      expect(ErrorNotifier).to receive(:notify).with(
        a_string_including("buyer was NOT made whole"),
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

    it "routes the notification to its persisted chat room" do
      failed_refund_exception.update!(owner: "refund-taskforce", notification_room: "risk")

      expect(InternalNotificationMailer).to receive(:notify)
        .with(hash_including(room_name: "risk")).and_return(mailer)
      expect(mailer).to receive(:deliver_now)
      allow(ErrorNotifier).to receive(:notify)

      described_class.new.perform(failed_refund_exception.id)
    end

    it "states that the retained processor fee was not reversed" do
      refund.update!(retained_fee_cents: 87)

      expect(InternalNotificationMailer).to receive(:notify).with(
        hash_including(
          message_text: a_string_including(
            "87-cent processor fee retained via a separate credit was NOT reversed"
          )
        )
      ).and_return(mailer)
      expect(mailer).to receive(:deliver_now)
      expect(ErrorNotifier).to receive(:notify)
        .with(anything, context: hash_including(retained_fee_cents: 87))

      described_class.new.perform(failed_refund_exception.id)
    end

    it "does not invent a reason when no balance reversal was recorded" do
      failed_refund_exception.update!(balance_reversed: false)

      expect(InternalNotificationMailer).to receive(:notify).with(
        hash_including(
          message_text: satisfy do |message|
            message.include?("Nothing was reversed automatically") &&
              message.include?("Review the exception before changing") &&
              !message.include?("because money also moved outside")
          end
        )
      ).and_return(mailer)
      expect(mailer).to receive(:deliver_now)
      allow(ErrorNotifier).to receive(:notify)

      described_class.new.perform(failed_refund_exception.id)
    end

    it "marks the notification sent even when the Sentry capture fails" do
      expect(InternalNotificationMailer).to receive(:notify).and_return(mailer)
      expect(mailer).to receive(:deliver_now)
      expect(ErrorNotifier).to receive(:notify).and_raise("sentry unavailable")

      expect { described_class.new.perform(failed_refund_exception.id) }.not_to raise_error

      expect(failed_refund_exception.reload.notification_sent_at).to be_present
    end

    it "stops attempting delivery once the failure cap is reached" do
      failed_refund_exception.update!(notification_failures: FailedRefundException::MAX_NOTIFICATION_FAILURES)
      expect(InternalNotificationMailer).not_to receive(:notify)
      expect(ErrorNotifier).not_to receive(:notify)

      described_class.new.perform(failed_refund_exception.id)

      expect(failed_refund_exception.reload.notification_failures)
        .to eq(FailedRefundException::MAX_NOTIFICATION_FAILURES)
    end

    it "leaves the record pending when delivery fails so Sidekiq can retry" do
      expect(InternalNotificationMailer).to receive(:notify).and_return(mailer)
      expect(mailer).to receive(:deliver_now).and_raise("mail unavailable")
      expect(ErrorNotifier).not_to receive(:notify)

      expect { described_class.new.perform(failed_refund_exception.id) }
        .to raise_error("mail unavailable")

      expect(failed_refund_exception.reload).to have_attributes(
        notification_failures: 1,
        notification_sent_at: nil
      )
    end

    it "does not notify again after delivery is recorded" do
      failed_refund_exception.update!(notification_sent_at: Time.current)
      expect(InternalNotificationMailer).not_to receive(:notify)
      expect(ErrorNotifier).not_to receive(:notify)

      described_class.new.perform(failed_refund_exception.id)

      expect(failed_refund_exception.reload.notification_failures).to eq(0)
    end

    it "does not notify an exception that was resolved before the job ran" do
      failed_refund_exception.resolve!(resolution: "Resolved before notification delivery")
      expect(InternalNotificationMailer).not_to receive(:notify)
      expect(ErrorNotifier).not_to receive(:notify)

      described_class.new.perform(failed_refund_exception.id)

      expect(failed_refund_exception.reload.notification_failures).to eq(0)
    end
  end
end
