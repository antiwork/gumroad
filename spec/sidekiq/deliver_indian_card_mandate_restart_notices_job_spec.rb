# frozen_string_literal: true

require "spec_helper"

describe DeliverIndianCardMandateRestartNoticesJob do
  let(:subscription) { create(:subscription) }

  it "is configured for the low queue with a unique lock" do
    expect(described_class.sidekiq_options["queue"]).to eq(:low)
    expect(described_class.sidekiq_options["lock"]).to eq(:until_executed)
  end

  describe ".schedule_retry" do
    it "schedules the job after the retry delay" do
      freeze_time do
        described_class.schedule_retry(subscription.id)

        expect(described_class.jobs.map { [_1["args"], _1["at"]] }).to eq([[[subscription.id], described_class::RETRY_DELAY.from_now.to_f]])
      end
    end

    it "reports instead of raising when the enqueue fails, leaving the markers for the next delivery" do
      error = Redis::CannotConnectError.new("redis down")
      allow(described_class).to receive(:perform_in).and_raise(error)

      expect(ErrorNotifier).to receive(:notify).with(error, subscription_id: subscription.id)

      expect { described_class.schedule_retry(subscription.id) }.not_to raise_error
    end
  end

  describe "#perform" do
    it "delivers a pending abandonment notice and clears its marker" do
      subscription.update!(indian_card_mandate_restart_abandoned_notice_pending: true)

      expect { described_class.new.perform(subscription.id) }
        .to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_indian_card_mandate_invalid).with(subscription.id, true).once

      expect(subscription.reload).not_to be_indian_card_mandate_restart_abandoned_notice_pending
    end

    it "delivers pending restart notifications and clears their marker" do
      subscription.update!(indian_card_mandate_restart_completed_notice_pending: true)

      expect_any_instance_of(Subscription).to receive(:send_restart_notifications!).once

      described_class.new.perform(subscription.id)

      expect(subscription.reload).not_to be_indian_card_mandate_restart_completed_notice_pending
    end

    context "when a completed notice is owed" do
      before { subscription.update!(indian_card_mandate_restart_completed_notice_pending: true) }

      def expect_dropped_without_notifications
        expect_any_instance_of(Subscription).not_to receive(:send_restart_notifications!)

        described_class.new.perform(subscription.id)

        subscription.reload
        expect(subscription).not_to be_indian_card_mandate_restart_completed_notice_pending
        expect(subscription.indian_card_mandate_restart_notice_owed).to be(false)
        expect(subscription.indian_card_mandate_restart_notice_recorded_at).to be_nil
      end

      it "sends nothing and clears the marker once the subscription has failed" do
        subscription.update!(failed_at: 1.hour.ago)

        expect_dropped_without_notifications
      end

      it "sends nothing and clears the marker once the subscription has ended" do
        subscription.update!(ended_at: 1.hour.ago)

        expect_dropped_without_notifications
      end

      it "sends nothing and clears the marker once the subscription has been deactivated again" do
        subscription.update!(cancelled_at: 1.hour.ago, deactivated_at: 1.hour.ago)

        expect_dropped_without_notifications
      end

      it "sends the notifications for a pending cancellation that still has access" do
        subscription.update!(cancelled_at: 3.days.from_now)
        expect(subscription).to be_alive

        expect_any_instance_of(Subscription).to receive(:send_restart_notifications!).once

        described_class.new.perform(subscription.id)

        expect(subscription.reload).not_to be_indian_card_mandate_restart_completed_notice_pending
      end

      it "sends the notifications for a subscription that is still alive" do
        expect_any_instance_of(Subscription).to receive(:send_restart_notifications!).once

        described_class.new.perform(subscription.id)

        expect(subscription.reload).not_to be_indian_card_mandate_restart_completed_notice_pending
      end
    end

    it "still delivers an abandonment notice for a subscription that has ended" do
      subscription.update!(ended_at: 1.hour.ago, deactivated_at: 1.hour.ago, indian_card_mandate_restart_abandoned_notice_pending: true)

      expect { described_class.new.perform(subscription.id) }
        .to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_indian_card_mandate_invalid).with(subscription.id, true).once

      expect(subscription.reload).not_to be_indian_card_mandate_restart_abandoned_notice_pending
    end

    it "keeps a marker whose delivery raised, so Sidekiq's retry delivers it" do
      subscription.update!(indian_card_mandate_restart_completed_notice_pending: true)
      allow_any_instance_of(Subscription).to receive(:send_restart_notifications!).and_raise(Redis::CannotConnectError, "redis down")

      expect { described_class.new.perform(subscription.id) }.to raise_error(Redis::CannotConnectError)

      expect(subscription.reload).to be_indian_card_mandate_restart_completed_notice_pending
    end

    it "keeps an abandonment that went out when the restart notifications then fail, so a retry does not repeat it" do
      subscription.update!(indian_card_mandate_restart_abandoned_notice_pending: true, indian_card_mandate_restart_completed_notice_pending: true)
      allow_any_instance_of(Subscription).to receive(:send_restart_notifications!).and_raise(Redis::CannotConnectError, "redis down")

      expect { described_class.new.perform(subscription.id) }.to raise_error(Redis::CannotConnectError)

      expect(subscription.reload).not_to be_indian_card_mandate_restart_abandoned_notice_pending
      expect(subscription).to be_indian_card_mandate_restart_completed_notice_pending
    end

    it "sends nothing without a marker" do
      expect_any_instance_of(Subscription).not_to receive(:send_restart_notifications!)

      expect { described_class.new.perform(subscription.id) }
        .not_to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_indian_card_mandate_invalid)
    end

    it "ignores a subscription that no longer exists" do
      expect { described_class.new.perform(0) }.not_to raise_error
    end
  end
end
