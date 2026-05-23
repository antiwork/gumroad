# frozen_string_literal: true

require "test_helper"

class ChargeDeclinedReminderWorkerTest < ActiveSupport::TestCase
  self.described_class = ChargeDeclinedReminderWorker
  self.rspec_metadata = { vcr: true }



  context_ ChargeDeclinedReminderWorker, :vcr do
    before do
      @product = create(:membership_product, user: create(:user), subscription_duration: :monthly)
      @subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @product)
      @purchase = create(:purchase, link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: true, subscription: @subscription)
    end

  test "doesn't send email on test_subscriptions" do
      @subscription.update!(is_test_subscription: true)

      expect do
        described_class.new.perform(@subscription.id)
      end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_card_declined_warning).with(@subscription.id)
    end

  test "doesn't send email when the subscription is NOT overdue for a charge" do
      travel_to @subscription.end_time_of_subscription - 1.hour do
        expect do
          described_class.new.perform(@subscription.id)
        end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_card_declined_warning).with(@subscription.id)
      end
    end

  test "sends email when the subscription is overdue for a charge" do
      travel_to @subscription.end_time_of_subscription + 1.hour do
        expect do
          described_class.new.perform(@subscription.id)
        end.to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_card_declined_warning).with(@subscription.id)
      end
    end

  context_ "subscription is cancelled" do
      before do
        @subscription.cancel!
      end

  test "doesn't send email on subscriptions" do
        expect do
          described_class.new.perform(@subscription.id)
        end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_card_declined_warning).with(@subscription.id)
      end
    end

  context_ "subscription has failed" do
      before do
        @subscription.unsubscribe_and_fail!
      end

  test "doesn't send email on subscriptions" do
        expect do
          described_class.new.perform(@subscription.id)
        end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_card_declined_warning).with(@subscription.id)
      end
    end

  context_ "subscription has ended" do
      before do
        @subscription.end_subscription!
      end

  test "calls charge on subscriptions" do
        expect do
          described_class.new.perform(@subscription.id)
        end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_card_declined_warning).with(@subscription.id)
      end
    end
  end
end
