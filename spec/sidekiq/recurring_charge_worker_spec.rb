# frozen_string_literal: true

require "spec_helper"

describe RecurringChargeWorker, :vcr do
  include ManageSubscriptionHelpers

  before do
    @product = create(:subscription_product, user: create(:user))
    @subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @product)
  end

  it "doesn't call charge on test_subscriptions" do
    @product.user.credit_card = create(:credit_card)
    @product.user.save!
    subscription = create(:subscription, user: @product.user, link: @product)
    subscription.is_test_subscription = true
    subscription.save!
    create(:test_purchase, seller: @product.user, purchaser: @product.user, link: @product, price_cents: @product.price_cents,
                           is_original_subscription_purchase: true, subscription:)
    expect_any_instance_of(Subscription).to_not receive(:charge!)
    described_class.new.perform(subscription.id)
  end

  it "doesn't call charge on free purchases" do
    link = create(:product, user: create(:user), price_cents: 0, price_range: "0+")
    subscription = create(:subscription, user: create(:user), link:)
    create(:free_purchase, link:, price_cents: 0, is_original_subscription_purchase: true, subscription:)
    expect_any_instance_of(Subscription).to_not receive(:charge!)
    described_class.new.perform(subscription.id)
  end

  it "doesn't call charge if there was a purchase made the period for a monthly subscription" do
    link = create(:product, user: create(:user), subscription_duration: "monthly")
    subscription = create(:subscription, user: create(:user), link:)
    create(:purchase, link:, price_cents: link.price_cents, is_original_subscription_purchase: true, subscription:)
    expect_any_instance_of(Subscription).to_not receive(:charge!)
    described_class.new.perform(subscription.id)
  end

  it "doesn't call charge if there was a purchase made the period for a yearly subscription" do
    link = create(:product, user: create(:user), subscription_duration: "yearly")
    subscription = create(:subscription, user: create(:user), link:)
    create(:purchase, link:, price_cents: link.price_cents, is_original_subscription_purchase: true, subscription:)
    expect_any_instance_of(Subscription).to_not receive(:charge!)
    described_class.new.perform(subscription.id)
  end

  it "doesn't call `charge` when invoked one day before the subscription period end date" do
    product = create(:product, user: create(:user), subscription_duration: "yearly")
    subscription = create(:subscription, user: create(:user), link: product)
    create(:purchase, link: product, price_cents: product.price_cents, is_original_subscription_purchase: true, subscription:)
    travel_to(subscription.period.from_now - 1.day) do
      expect_any_instance_of(Subscription).to_not receive(:charge!)
      described_class.new.perform(subscription.id)
    end
  end

  it "calls `charge` when invoked at the end of the subscription period" do
    create(:purchase, link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: true, subscription: @subscription)
    travel_to(@subscription.period.from_now) do
      expect_any_instance_of(Subscription).to receive(:charge!)
      described_class.new.perform(@subscription.id)
    end
  end

  it "doesn't call `charge` when invoked early, after refunded purchase" do
    travel_to(Time.zone.local(2018, 6, 15) - @subscription.period * 2)
    create(:purchase, link: @product, is_original_subscription_purchase: true, subscription: @subscription)

    travel_to(Time.current + @subscription.period)
    create(:purchase, link: @product, subscription: @subscription, stripe_refunded: true)

    travel_to(Time.current + 5.days)
    expect_any_instance_of(Subscription).not_to receive(:charge!)
    described_class.new.perform(@subscription.id)
  end

  it "doesn't call `charge` when invoked one day after the subscription period end date but there's already a purchase in progress" do
    create(:purchase, link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: true, subscription: @subscription)
    create(:purchase, link: @product, price_cents: @product.price_cents, subscription: @subscription, purchase_state: "in_progress")
    travel_to(@subscription.period.from_now + 1.day) do
      expect(@subscription.has_a_charge_in_progress?).to be true
      expect_any_instance_of(Subscription).not_to receive(:charge!)
      described_class.new.perform(@subscription.id)
    end
  end

  it "calls `charge` when invoked one day after the subscription period end date" do
    create(:purchase, link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: true, subscription: @subscription)
    travel_to(@subscription.period.from_now + 1.day) do
      expect_any_instance_of(Subscription).to receive(:charge!)
      described_class.new.perform(@subscription.id)
    end
  end

  it "calls charge when invoked one year after the subscription period end date" do
    create(:purchase, link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: true, subscription: @subscription)
    travel_to(@subscription.period.from_now + 1.year) do
      expect_any_instance_of(Subscription).to receive(:charge!)
      described_class.new.perform(@subscription.id)
    end
  end

  it "calls `charge` for subscriptions purchased on 30th January when invoked at the end of the subscription period" do
    travel_to(Time.current.change(year: 2018, month: 1, day: 30)) do
      create(:purchase, link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: true, subscription: @subscription)
    end
    travel_to(@subscription.period.from_now) do
      expect_any_instance_of(Subscription).to receive(:charge!)
      described_class.new.perform(@subscription.id)
    end
  end

  describe "with ignore_consecutive_failures = true" do
    context "when last purchase failed" do
      before { create(:membership_purchase, subscription: @subscription, link: @product, purchase_state: "failed") }

      it "does not call `charge`" do
        allow_any_instance_of(Subscription).to receive(:seconds_overdue_for_charge).and_return(5.days - 1.minute)

        travel_to(@subscription.period.from_now) do
          expect_any_instance_of(Subscription).not_to receive(:charge!)
          expect_any_instance_of(Subscription).not_to receive(:unsubscribe_and_fail!)
          described_class.new.perform(@subscription.id, true)
        end
      end

      it "calls `unsubscribe_and_fail!` when the subscription is at least 5 days overdue for a charge" do
        allow_any_instance_of(Subscription).to receive(:seconds_overdue_for_charge).and_return(5.days + 1.minute)

        travel_to(@subscription.period.from_now) do
          expect_any_instance_of(Subscription).not_to receive(:charge!)
          expect_any_instance_of(Subscription).to receive(:unsubscribe_and_fail!)
          described_class.new.perform(@subscription.id, true)
        end
      end
    end
  end

  describe "subscription is cancelled" do
    before do
      @product = create(:product, user: create(:user))
      @subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @product, cancelled_at: 1.hour.ago)
      create(:purchase, link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: true, subscription: @subscription)
    end

    it "calls charge on subscriptions" do
      expect_any_instance_of(Subscription).to_not receive(:charge!)
      described_class.new.perform(@subscription.id)
    end
  end

  describe "subscription has failed" do
    before do
      @product = create(:product, user: create(:user))
      @subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @product, failed_at: Time.current)
      create(:purchase, link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: true, subscription: @subscription)
    end

    it "calls charge on subscriptions" do
      expect_any_instance_of(Subscription).to_not receive(:charge!)
      described_class.new.perform(@subscription.id)
    end
  end

  describe "subscription has ended" do
    before do
      create(:purchase, link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: true, subscription: @subscription)
      @subscription.update_attribute(:ended_at, Time.current)
    end

    it "calls charge on subscriptions" do
      expect_any_instance_of(Subscription).to_not receive(:charge!)
      described_class.new.perform(@subscription.id)
    end
  end

  describe "subscription has a pending plan change" do
    before do
      setup_subscription
      @older_plan_change = create(:subscription_plan_change, subscription: @subscription, created_at: 1.day.ago)
      @plan_change = create(:subscription_plan_change, subscription: @subscription, tier: @new_tier, recurrence: "monthly")
      travel_to(@originally_subscribed_at + @subscription.period + 1.minute)
    end

    it "updates the variants and prices before charging" do
      described_class.new.perform(@subscription.id)

      updated_purchase = @subscription.reload.original_purchase

      expect(updated_purchase.variant_attributes).to eq [@new_tier]
      expect(@subscription.price).to eq @monthly_product_price
      expect(updated_purchase.displayed_price_cents).to eq @new_tier_monthly_price.price_cents
    end

    it "marks the plan change deleted and applied, and marks older plan changes deleted" do
      described_class.new.perform(@subscription.id)

      @plan_change.reload
      @older_plan_change.reload
      expect(@plan_change).to be_deleted
      expect(@plan_change).to be_applied
      expect(@older_plan_change).to be_deleted
      expect(@older_plan_change).not_to be_applied
    end

    it "charges the new price" do
      expect do
        described_class.new.perform(@subscription.id)
      end.to change { @subscription.purchases.not_is_original_subscription_purchase.not_is_archived_original_subscription_purchase.count }.by(1)

      last_purchase = @subscription.purchases.not_is_original_subscription_purchase.last
      expect(last_purchase.displayed_price_cents).to eq @new_tier_monthly_price.price_cents
    end

    it "switches the subscription to the new flat fee" do
      @subscription.update!(flat_fee_applicable: false)
      expect do
        described_class.new.perform(@subscription.id)
      end.to change { @subscription.reload.flat_fee_applicable? }.to(true)
    end

    context "for a PWYW tier" do
      it "sets the original purchase price to the perceived_price_cents" do
        @new_tier.update!(customizable_price: true)
        @plan_change.update!(perceived_price_cents: 100_00)

        described_class.new.perform(@subscription.id)

        updated_purchase = @subscription.reload.original_purchase

        expect(updated_purchase.displayed_price_cents).to eq 100_00
      end
    end

    context "when the price has changed" do
      it "relies on the price at the time of the downgrade" do
        @plan_change.update!(perceived_price_cents: 2_50)

        described_class.new.perform(@subscription.id)

        updated_purchase = @subscription.reload.original_purchase

        expect(updated_purchase.displayed_price_cents).to eq 2_50
      end
    end

    context "when the recurrence option has been deleted" do
      it "still uses that recurrence" do
        @monthly_product_price.mark_deleted!

        described_class.new.perform(@subscription.id)

        expect(@subscription.reload.price).to eq @monthly_product_price
      end
    end

    context "when the tier has been deleted" do
      it "still uses that tier" do
        @new_tier.mark_deleted!

        described_class.new.perform(@subscription.id)

        updated_purchase = @subscription.reload.original_purchase

        expect(updated_purchase.variant_attributes).to eq [@new_tier]
      end
    end

    context "when the plan change is not currently applicable" do
      it "does not apply the plan change" do
        @plan_change.update!(for_product_price_change: true, effective_on: 1.day.from_now)

        expect do
          described_class.new.perform(@subscription.id)
        end.not_to change { @plan_change.applied? }.from(false)

        expect(@subscription.reload.original_purchase).to eq @original_purchase
      end
    end

    describe "workflows" do
      before do
        workflow = create(:variant_workflow, seller: @product.user, link: @product, base_variant: @new_tier)
        @installment = create(:installment, link: @product, base_variant: @new_tier, workflow:, published_at: 1.day.ago)
        create(:installment_rule, installment: @installment, delayed_delivery_time: 1.day)
      end

      it "schedules tier workflows if tier has changed" do
        described_class.new.perform(@subscription.id)

        purchase_id = @subscription.reload.original_purchase.id
        expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@installment.id, 1, purchase_id, nil, nil)
      end

      it "does not schedule workflows if tier has not changed" do
        @plan_change.update!(tier: @original_tier)

        described_class.new.perform(@subscription.id)

        expect(SendWorkflowInstallmentWorker.jobs.size).to eq(0)
      end
    end

    describe "integrations" do
      it "enqueues integrations update if tier has changed" do
        described_class.new.perform(@subscription.id)

        expect(UpdateIntegrationsOnTierChangeWorker).to have_enqueued_sidekiq_job(@subscription.id)
      end

      it "does not enqueue integrations update if tier has not changed" do
        @plan_change.update!(tier: @original_tier)

        described_class.new.perform(@subscription.id)

        expect(UpdateIntegrationsOnTierChangeWorker.jobs.size).to eq(0)
      end
    end
  end

  describe "non-tiered subscription has a pending plan change" do
    before do
      travel_to(4.months.ago) do
        product = create(:subscription_product, subscription_duration: BasePrice::Recurrence::MONTHLY, price_cents: 12_99)
        @variant = create(:variant, variant_category: create(:variant_category, link: product))
        @monthly_price = product.prices.find_by!(recurrence: BasePrice::Recurrence::MONTHLY)
        @quarterly_price = create(:price, link: product, recurrence: BasePrice::Recurrence::QUARTERLY, price_cents: 30_00)
        @subscription = create(:subscription, credit_card: create(:credit_card), link: product, price: @quarterly_price)
        @original_purchase = create(:purchase, is_original_subscription_purchase: true,
                                               link: product,
                                               subscription: @subscription,
                                               variant_attributes: [@variant],
                                               credit_card: @subscription.credit_card,
                                               price: @quarterly_price,
                                               price_cents: @quarterly_price.price_cents,
                                               purchase_state: "successful")

        @plan_change = create(:subscription_plan_change, subscription: @subscription,
                                                         tier: nil,
                                                         recurrence: BasePrice::Recurrence::MONTHLY,
                                                         perceived_price_cents: 5_00)
      end
    end

    it "updates the price before charging" do
      described_class.new.perform(@subscription.id)

      updated_purchase = @subscription.reload.original_purchase
      expect(updated_purchase.variant_attributes).to eq [@variant]
      expect(@subscription.price).to eq @monthly_price
      expect(updated_purchase.displayed_price_cents).to eq @plan_change.perceived_price_cents

      last_charge = @subscription.purchases.successful.last
      expect(last_charge.id).not_to eq @original_purchase.id
      expect(last_charge.displayed_price_cents).to eq @plan_change.perceived_price_cents
    end
  end

  describe "seller is banned" do
    before do
      @seller = create(:user)
      @product = create(:product, user: @seller)
      @subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @product)
      create(:purchase, link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: true, subscription: @subscription)

      @seller.user_risk_state = "suspended_for_fraud"
      @seller.save
    end

    describe "subscription_id provided" do
      it "does not call charge on a subscription" do
        expect_any_instance_of(Subscription).to_not receive(:charge!)
        described_class.new.perform(@subscription.id)
      end
    end
  end

  describe "subscriber removes his credit card" do
    it "calls `charge` on subscriptions" do
      @product = create(:product, user: create(:user), subscription_duration: "monthly")
      @subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @product)
      purchase = create(:purchase, link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: true, subscription: @subscription)

      subscriber = @subscription.user
      subscriber.credit_card = nil
      subscriber.save!

      purchase.update(succeeded_at: 3.days.ago)

      travel_to(1.month.from_now) do
        described_class.new.perform(@subscription.id)
        expect(Purchase.last.purchase_state).to eq "failed"
        expect(Purchase.last.error_code).to eq PurchaseErrorCode::CREDIT_CARD_NOT_PROVIDED
      end
    end
  end

  describe "subscription has free trial" do
    before do
      product = create(:membership_product, free_trial_enabled: true, free_trial_duration_amount: 1, free_trial_duration_unit: :week)
      purchase = create(:membership_purchase, link: product, purchase_state: "not_charged", is_free_trial_purchase: true, price_cents: 300)
      @subscription = purchase.subscription
      @subscription.update!(free_trial_ends_at: 1.week.from_now, credit_card: create(:credit_card))
    end

    context "free trial has ended" do
      it "charges the user" do
        travel_to(8.days.from_now) do
          expect do
            described_class.new.perform(@subscription.id)
          end.to change { @subscription.purchases.successful.count }.by(1)
        end
      end
    end

    context "free trial has not yet ended" do
      it "does not charge the user" do
        expect_any_instance_of(Subscription).not_to receive(:charge!)
        described_class.new.perform(@subscription.id)
      end
    end
  end

  context "subscription has a fixed-duration offer code that makes the product free for the first billing period" do
    before do
      offer_code = create(:offer_code, products: [@product], duration_in_months: 1, amount_cents: @product.price_cents)
      create(:purchase, link: @product, price_cents: 0, is_original_subscription_purchase: true, subscription: @subscription, offer_code:).create_purchase_offer_code_discount(offer_code:, offer_code_amount: @product.price_cents, offer_code_is_percent: false, pre_discount_minimum_price_cents: @product.price_cents, duration_in_billing_cycles: 1)
    end

    it "calls charge when the offer code has elapsed" do
      travel_to(@subscription.period.from_now) do
        expect_any_instance_of(Subscription).to receive(:charge!)
        described_class.new.perform(@subscription.id)
      end
    end
  end
end
