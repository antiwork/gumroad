# frozen_string_literal: true

require "spec_helper"

describe FreeTrialExpiringReminderWorker, :vcr do
  let(:purchase) { create(:free_trial_membership_purchase) }
  let(:subscription) { purchase.subscription }

  it "sends an email if the subscription is currently in a free trial" do
    expect do
      described_class.new.perform(subscription.id)
    end.to have_enqueued_mail(CustomerLowPriorityMailer, :free_trial_expiring_soon).with(subscription.id)
  end

  it "doesn't send email for a test subscription" do
    subscription.update!(is_test_subscription: true)

    expect do
      described_class.new.perform(subscription.id)
    end.to_not have_enqueued_mail(CustomerLowPriorityMailer, :free_trial_expiring_soon).with(subscription.id)
  end

  it "doesn't send email if the subscription is no longer in a free trial" do
    subscription.update!(free_trial_ends_at: 1.day.ago)

    expect do
      described_class.new.perform(subscription.id)
    end.to_not have_enqueued_mail(CustomerLowPriorityMailer, :free_trial_expiring_soon).with(subscription.id)
  end

  it "doesn't send email if the subscription is pending cancellation" do
    subscription.update!(cancelled_at: 1.day.from_now)

    expect do
      described_class.new.perform(subscription.id)
    end.to_not have_enqueued_mail(CustomerLowPriorityMailer, :free_trial_expiring_soon).with(subscription.id)
  end

  it "doesn't send email if the subscription is cancelled" do
    subscription.update!(cancelled_at: 1.day.ago)

    expect do
      described_class.new.perform(subscription.id)
    end.to_not have_enqueued_mail(CustomerLowPriorityMailer, :free_trial_expiring_soon).with(subscription.id)
  end

  it "doesn't send email for a subscription without a free trial" do
    purchase = create(:membership_purchase)
    subscription = purchase.subscription

    expect do
      described_class.new.perform(subscription.id)
    end.to_not have_enqueued_mail(CustomerLowPriorityMailer, :free_trial_expiring_soon).with(subscription.id)
  end

  it "doesn't send duplicate emails" do
    expect do
      described_class.new.perform(subscription.id)
      described_class.new.perform(subscription.id)
    end.to have_enqueued_mail(CustomerLowPriorityMailer, :free_trial_expiring_soon).with(subscription.id).once
  end

  it "does not strand the reminder key when the email enqueue raises" do
    subscription_id = subscription.id
    adapter = MailDeliveryJob.queue_adapter
    allow(adapter).to receive(:enqueue).and_raise("queue unavailable")

    expect { described_class.new.perform(subscription_id) }.to raise_error("queue unavailable")
    expect(SentEmailInfo.mailer_exists?("CustomerLowPriorityMailer", "free_trial_expiring_soon", subscription_id)).to be(false)

    allow(adapter).to receive(:enqueue).and_call_original
    expect do
      described_class.new.perform(subscription_id)
      described_class.new.perform(subscription_id)
    end.to have_enqueued_mail(CustomerLowPriorityMailer, :free_trial_expiring_soon).with(subscription_id).on_queue("low").once
  end

  it "retries an enqueue refusal instead of recording it as success" do
    subscription_id = subscription.id
    adapter = MailDeliveryJob.queue_adapter
    allow(adapter).to receive(:enqueue).and_raise(ActiveJob::EnqueueError, "queue unavailable")

    expect do
      described_class.new.perform(subscription_id)
    end.to raise_error(StandardError, "Free-trial expiry reminder was not enqueued")
    expect(SentEmailInfo.mailer_exists?("CustomerLowPriorityMailer", "free_trial_expiring_soon", subscription_id)).to be(false)

    allow(adapter).to receive(:enqueue).and_call_original
    expect do
      described_class.new.perform(subscription_id)
    end.to have_enqueued_mail(CustomerLowPriorityMailer, :free_trial_expiring_soon).with(subscription_id).once
  end

  it "does not record a key when delivery returns nil" do
    subscription_id = subscription.id
    allow_any_instance_of(ActionMailer::MessageDelivery).to receive(:deliver_later).and_return(nil)

    expect do
      described_class.new.perform(subscription_id)
    end.to raise_error(StandardError, "Free-trial expiry reminder was not enqueued")
    expect(SentEmailInfo.mailer_exists?("CustomerLowPriorityMailer", "free_trial_expiring_soon", subscription_id)).to be(false)
  end

  it "continues respecting the existing reminder key" do
    subscription_id = subscription.id
    SentEmailInfo.set_key!(SentEmailInfo.mailer_key_digest("CustomerLowPriorityMailer", "free_trial_expiring_soon", subscription_id))

    expect do
      described_class.new.perform(subscription_id)
    end.not_to have_enqueued_mail(CustomerLowPriorityMailer)
  end

  it "propagates a marker failure after the email was accepted so the worker can retry" do
    subscription_id = subscription.id
    allow(SentEmailInfo).to receive(:set_key!).and_raise("marker unavailable")

    expect do
      expect { described_class.new.perform(subscription_id) }.to raise_error("marker unavailable")
    end.to have_enqueued_mail(CustomerLowPriorityMailer, :free_trial_expiring_soon).with(subscription_id).once
    expect(SentEmailInfo.mailer_exists?("CustomerLowPriorityMailer", "free_trial_expiring_soon", subscription_id)).to be(false)

    allow(SentEmailInfo).to receive(:set_key!).and_call_original
    expect do
      described_class.new.perform(subscription_id)
    end.to have_enqueued_mail(CustomerLowPriorityMailer, :free_trial_expiring_soon).with(subscription_id).once
  end

  context "with runtime uniqueness enabled" do
    around do |example|
      SidekiqUniqueJobs.use_config(enabled: true) { example.run }
    end

    it "serializes overlapping jobs across queues without dropping the second enqueue" do
      subscription_id = subscription.id
      described_class.clear
      described_class.perform_async(subscription_id)
      described_class.set(queue: "low").perform_async(subscription_id)
      first_job, second_job = described_class.jobs
      expect(first_job.fetch("jid")).not_to eq(second_job.fetch("jid"))
      checked_conflict = false

      allow(MailDeliveryJob.queue_adapter).to receive(:enqueue).and_wrap_original do |original, job|
        unless checked_conflict
          checked_conflict = true
          expect do
            SidekiqUniqueJobs::Middleware::Server.new.call(described_class.new, second_job, "low") do
              described_class.new.perform(subscription_id)
            end
          end.to raise_error(SidekiqUniqueJobs::Conflict)
        end
        original.call(job)
      end

      expect do
        SidekiqUniqueJobs::Middleware::Server.new.call(described_class.new, first_job, "default") do
          described_class.new.perform(subscription_id)
        end
      end.to have_enqueued_mail(CustomerLowPriorityMailer, :free_trial_expiring_soon).with(subscription_id).once

      expect do
        SidekiqUniqueJobs::Middleware::Server.new.call(described_class.new, second_job, "low") do
          described_class.new.perform(subscription_id)
        end
      end.not_to have_enqueued_mail(CustomerLowPriorityMailer)
    end

    it "releases the runtime lock after an enqueue failure and allows a successful retry" do
      subscription_id = subscription.id
      described_class.clear
      described_class.perform_async(subscription_id)
      job = described_class.jobs.sole
      allow(MailDeliveryJob.queue_adapter).to receive(:enqueue).and_raise("queue unavailable")

      expect do
        SidekiqUniqueJobs::Middleware::Server.new.call(described_class.new, job, "default") do
          described_class.new.perform(subscription_id)
        end
      end.to raise_error("queue unavailable")

      allow(MailDeliveryJob.queue_adapter).to receive(:enqueue).and_call_original
      expect do
        SidekiqUniqueJobs::Middleware::Server.new.call(described_class.new, job, "default") do
          described_class.new.perform(subscription_id)
        end
      end.to have_enqueued_mail(CustomerLowPriorityMailer, :free_trial_expiring_soon).with(subscription_id).once
    end
  end

  it "doesn't send email while an Indian card mandate update is required" do
    subscription.update!(renewal_disabled_due_to_indian_card_mandate: true)
    allow_any_instance_of(Subscription).to receive(:india_card_mandate_reliability_enabled?).and_return(true)

    expect do
      described_class.new.perform(subscription.id)
    end.to_not have_enqueued_mail(CustomerLowPriorityMailer, :free_trial_expiring_soon).with(subscription.id)
  end
end
