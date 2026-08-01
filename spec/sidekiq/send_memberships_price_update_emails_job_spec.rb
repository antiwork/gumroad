# frozen_string_literal: true

describe SendMembershipsPriceUpdateEmailsJob do
  describe "#perform" do
    let(:subscription) { create(:subscription) }
    let(:effective_on) { rand(1..7).days.from_now.to_date }

    before do
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    end

    context "when there are applicable subscription plan changes" do
      let!(:applicable_plan_change) do
        create(:subscription_plan_change, for_product_price_change: true, subscription:,
                                          effective_on:, perceived_price_cents: 20_00)
      end

      it "queues delivery without authorizing the new price" do
        subject.perform

        expect(applicable_plan_change.reload.notified_subscriber_at).to be_nil
        expect(subscription.reload.latest_applicable_plan_change).to be_nil
        expect(ActiveJob::Base.queue_adapter.enqueued_jobs.size).to eq(1)
        expect(ActiveJob::Base.queue_adapter.enqueued_jobs.first).to include(
          job: SendMembershipPriceUpdateEmailJob,
          args: [applicable_plan_change.id, applicable_plan_change.notification_claim_id],
          queue: "low",
        )
      end

      it "retries the notification when enqueueing raises" do
        applicable_plan_change.update!(effective_on: Date.current)
        raised = false
        allow(SendMembershipPriceUpdateEmailJob).to receive(:perform_later) do
          next double if raised
          raised = true
          raise Redis::CannotConnectError, "Redis is unavailable"
        end

        expect { subject.perform }.to raise_error(Redis::CannotConnectError)
        expect(applicable_plan_change.reload.notified_subscriber_at).to be_nil
        expect(applicable_plan_change.notification_claim_id).to be_nil
        expect(applicable_plan_change.notification_claimed_at).to be_nil
        expect(subscription.reload.latest_applicable_plan_change).to be_nil

        subject.perform

        expect(SendMembershipPriceUpdateEmailJob).to have_received(:perform_later).twice
        expect(applicable_plan_change.reload.notification_claim_id).to be_present
        expect(applicable_plan_change.notified_subscriber_at).to be_nil
        expect(subscription.reload.latest_applicable_plan_change).to be_nil
      end

      it "does not enqueue twice when another run overlaps the queue handoff" do
        allow(SendMembershipPriceUpdateEmailJob).to receive(:perform_later) do
          described_class.new.perform
          double
        end

        subject.perform

        expect(SendMembershipPriceUpdateEmailJob).to have_received(:perform_later).once
        expect(applicable_plan_change.reload.notification_claim_id).to be_present
        expect(applicable_plan_change.notification_claimed_at).to be_present
        expect(applicable_plan_change.notified_subscriber_at).to be_nil
      end

      it "does not enqueue while another notification claim is active", :freeze_time do
        applicable_plan_change.update!(notification_claim_id: SecureRandom.uuid, notification_claimed_at: 1.minute.ago)

        expect do
          subject.perform
        end.not_to change { applicable_plan_change.reload.notified_subscriber_at }

        expect(ActiveJob::Base.queue_adapter.enqueued_jobs).to be_empty
        expect(applicable_plan_change.notification_claimed_at).to eq(1.minute.ago)
      end

      it "recovers an expired notification claim", :freeze_time do
        expired_claim_id = SecureRandom.uuid
        applicable_plan_change.update!(
          notification_claim_id: expired_claim_id,
          notification_claimed_at: SubscriptionPlanChange::PRICE_CHANGE_NOTIFICATION_CLAIM_TTL.ago - 1.minute,
        )

        subject.perform

        expect(ActiveJob::Base.queue_adapter.enqueued_jobs.size).to eq(1)
        expect(applicable_plan_change.reload.notification_claim_id).not_to eq(expired_claim_id)
        expect(applicable_plan_change.notification_claimed_at).to eq(Time.current)
        expect(applicable_plan_change.notified_subscriber_at).to be_nil
      end

      it "does not queue notification emails for subscriptions pending cancellation" do
        subscription.update!(cancelled_at: effective_on + 1.day)

        expect do
          subject.perform
        end.not_to change { applicable_plan_change.reload.notified_subscriber_at }

        expect(ActiveJob::Base.queue_adapter.enqueued_jobs).to be_empty
      end

      it "does not queue notification emails for subscriptions that are fully cancelled" do
        subscription.update!(cancelled_at: 1.day.ago, deactivated_at: 1.day.ago)

        expect do
          subject.perform
        end.not_to change { applicable_plan_change.reload.notified_subscriber_at }

        expect(ActiveJob::Base.queue_adapter.enqueued_jobs).to be_empty
      end

      it "does not queue notification emails for subscriptions that have ended" do
        subscription.update!(ended_at: 1.day.ago, deactivated_at: 1.day.ago)

        expect do
          subject.perform
        end.not_to change { applicable_plan_change.reload.notified_subscriber_at }

        expect(ActiveJob::Base.queue_adapter.enqueued_jobs).to be_empty
      end

      it "does not queue notification emails for subscriptions that have failed" do
        subscription.update!(failed_at: 1.day.ago, deactivated_at: 1.day.ago)

        expect do
          subject.perform
        end.not_to change { applicable_plan_change.reload.notified_subscriber_at }

        expect(ActiveJob::Base.queue_adapter.enqueued_jobs).to be_empty
      end
    end

    context "when there are non-applicable subscription plan changes" do
      before do
        create(:subscription_plan_change, for_product_price_change: false, subscription:, effective_on:)
        create(:subscription_plan_change, for_product_price_change: true, subscription:, effective_on:, applied: true)
        create(:subscription_plan_change, for_product_price_change: true, subscription:, effective_on:, deleted_at: Time.current)
        create(:subscription_plan_change, for_product_price_change: true, subscription:, effective_on:, notified_subscriber_at: Time.current)
        create(:subscription_plan_change, for_product_price_change: true, subscription:, effective_on: 8.days.from_now.to_date)
      end

      it "does not send any emails" do
        subject.perform
        expect(ActiveJob::Base.queue_adapter.enqueued_jobs).to be_empty
      end
    end

    context "when there are no subscription plan changes" do
      it "does not send any emails" do
        subject.perform
        expect(ActiveJob::Base.queue_adapter.enqueued_jobs).to be_empty
      end
    end
  end
end
