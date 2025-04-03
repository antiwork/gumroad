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
end
