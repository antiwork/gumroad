# frozen_string_literal: true

require "spec_helper"

describe RecurringChargeReminderWorker, :vcr do
  include ManageSubscriptionHelpers

  before do
    setup_subscription
    travel_to @subscription.end_time_of_subscription - 6.days
    allow_any_instance_of(Subscription).to receive(:send_renewal_reminders?).and_return(true)
  end

  it "sends a reminder email about an upcoming charge" do
    expect do
      RecurringChargeReminderWorker.new.perform(@subscription.id)
    end.to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_renewal_reminder).with(@subscription.id)
  end

  it "does not send a reminder if the subscription is no longer alive" do
    @subscription.update!(failed_at: 1.day.ago)

    expect do
      RecurringChargeReminderWorker.new.perform(@subscription.id)
    end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_renewal_reminder).with(@subscription.id)
  end

  it "does not send a reminder if the subscription is pending cancellation" do
    @subscription.update!(cancelled_at: 1.day.from_now)

    expect do
      RecurringChargeReminderWorker.new.perform(@subscription.id)
    end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_renewal_reminder).with(@subscription.id)
  end

  it "does not send a reminder for a fixed-length subscription that has had its last charge" do
    @subscription.update!(charge_occurrence_count: 1)
    expect do
      RecurringChargeReminderWorker.new.perform(@subscription.id)
    end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_renewal_reminder).with(@subscription.id)
  end

  it "does not send a reminder if `send_renewal_reminders?` is false" do
    allow_any_instance_of(Subscription).to receive(:send_renewal_reminders?).and_return(false)

    expect do
      RecurringChargeReminderWorker.new.perform(@subscription.id)
    end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_renewal_reminder).with(@subscription.id)
  end

  it "does not send a reminder for a subscription still in a free trial" do
    @subscription.update!(free_trial_ends_at: 1.week.from_now)
    expect do
      RecurringChargeReminderWorker.new.perform(@subscription.id)
    end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_renewal_reminder).with(@subscription.id)
  end
end
