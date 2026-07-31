# frozen_string_literal: true

require "spec_helper"

describe SendMembershipPriceUpdateEmailJob do
  describe "#perform" do
    let(:subscription) { create(:subscription) }
    let(:claim_id) { SecureRandom.uuid }
    let(:subscription_plan_change) do
      create(
        :subscription_plan_change,
        for_product_price_change: true,
        subscription:,
        perceived_price_cents: 20_00,
        effective_on: Date.current,
        notification_claim_id: claim_id,
        notification_claimed_at: 1.minute.ago,
      )
    end
    let(:delivery) { double(deliver_now: true) }

    before do
      allow(CustomerLowPriorityMailer).to receive(:subscription_price_change_notification).and_return(delivery)
    end

    it "authorizes the new price only after delivering the notification", :freeze_time do
      with_versioning do
        version_count = subscription_plan_change.versions.size

        expect do
          subject.perform(subscription_plan_change.id, claim_id)
        end.to change { subscription_plan_change.reload.notified_subscriber_at }.from(nil).to(Time.current)

        expect(CustomerLowPriorityMailer).to have_received(:subscription_price_change_notification).with(
          subscription_id: subscription.id,
          new_price: 20_00
        ).once
        expect(delivery).to have_received(:deliver_now).once
        expect(subscription_plan_change.notification_claim_id).to be_nil
        expect(subscription_plan_change.notification_claimed_at).to be_nil
        expect(subscription.reload.latest_applicable_plan_change).to eq(subscription_plan_change)
        expect(subscription_plan_change.versions.size).to eq(version_count + 1)
      end
    end

    it "does not authorize the new price when delivery fails", :freeze_time do
      allow(delivery).to receive(:deliver_now).and_raise(Net::ReadTimeout)

      expect do
        subject.perform(subscription_plan_change.id, claim_id)
      end.to raise_error(Net::ReadTimeout)

      expect(subscription_plan_change.reload.notified_subscriber_at).to be_nil
      expect(subscription_plan_change.notification_claim_id).to eq(claim_id)
      expect(subscription_plan_change.notification_claimed_at).to eq(Time.current)
      expect(subscription.reload.latest_applicable_plan_change).to be_nil
    end

    it "retries a transient delivery failure and authorizes the price after success", :freeze_time do
      attempts = 0
      allow(delivery).to receive(:deliver_now) do
        attempts += 1
        raise Net::ReadTimeout if attempts == 1
      end
      job = described_class.new(subscription_plan_change.id, claim_id)

      expect(job).to receive(:retry_job).once
      expect { job.perform_now }.not_to raise_error
      expect(subscription_plan_change.reload.notified_subscriber_at).to be_nil
      expect(subscription_plan_change.notification_claim_id).to eq(claim_id)

      job.perform_now

      expect(delivery).to have_received(:deliver_now).twice
      expect(subscription_plan_change.reload.notified_subscriber_at).to eq(Time.current)
      expect(subscription_plan_change.notification_claim_id).to be_nil
      expect(subscription.reload.latest_applicable_plan_change).to eq(subscription_plan_change)
    end

    it "ignores a delivery job that no longer owns the claim" do
      replacement_claim_id = SecureRandom.uuid
      subscription_plan_change.update!(notification_claim_id: replacement_claim_id)

      subject.perform(subscription_plan_change.id, claim_id)

      expect(CustomerLowPriorityMailer).not_to have_received(:subscription_price_change_notification)
      expect(subscription_plan_change.reload.notification_claim_id).to eq(replacement_claim_id)
      expect(subscription_plan_change.notified_subscriber_at).to be_nil
    end

    it "does not deliver again after the notification is confirmed" do
      subject.perform(subscription_plan_change.id, claim_id)
      subject.perform(subscription_plan_change.id, claim_id)

      expect(delivery).to have_received(:deliver_now).once
    end
  end
end
