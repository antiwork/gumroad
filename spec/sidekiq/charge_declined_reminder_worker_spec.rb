# frozen_string_literal: true

require "spec_helper"

describe ChargeDeclinedReminderWorker, :vcr do
  before do
    @product = create(:membership_product, user: create(:user), subscription_duration: :monthly)
    @subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @product)
    @purchase = create(:purchase, link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: true, subscription: @subscription)
  end

  it "doesn't send email on test_subscriptions" do
    @subscription.update!(is_test_subscription: true)

    expect do
      described_class.new.perform(@subscription.id)
    end.to_not have_enqueued_mail(CustomerLowPriorityMailer, :subscription_card_declined_warning).with(@subscription.id)
  end

  it "doesn't send email when the subscription is NOT overdue for a charge" do
    travel_to @subscription.end_time_of_subscription - 1.hour do
      expect do
        described_class.new.perform(@subscription.id)
      end.to_not have_enqueued_mail(CustomerLowPriorityMailer, :subscription_card_declined_warning).with(@subscription.id)
    end
  end

  it "sends email when the subscription is overdue for a charge" do
    travel_to @subscription.end_time_of_subscription + 1.hour do
      expect do
        described_class.new.perform(@subscription.id)
      end.to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_card_declined_warning).with(@subscription.id)
    end
  end

  describe "subscription is cancelled" do
    before do
      @subscription.cancel!
    end

    it "doesn't send email on subscriptions" do
      expect do
        described_class.new.perform(@subscription.id)
      end.to_not have_enqueued_mail(CustomerLowPriorityMailer, :subscription_card_declined_warning).with(@subscription.id)
    end
  end

  describe "subscription has failed" do
    before do
      @subscription.unsubscribe_and_fail!
    end

    it "doesn't send email on subscriptions" do
      expect do
        described_class.new.perform(@subscription.id)
      end.to_not have_enqueued_mail(CustomerLowPriorityMailer, :subscription_card_declined_warning).with(@subscription.id)
    end
  end

  describe "subscription has ended" do
    before do
      @subscription.end_subscription!
    end

    it "calls charge on subscriptions" do
      expect do
        described_class.new.perform(@subscription.id)
      end.to_not have_enqueued_mail(CustomerLowPriorityMailer, :subscription_card_declined_warning).with(@subscription.id)
    end
  end
end
