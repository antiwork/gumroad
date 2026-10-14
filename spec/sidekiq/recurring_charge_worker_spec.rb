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

  it "does not charge while an Indian card mandate update is required",
     vcr: { cassette_name: "RecurringChargeWorker/doesn_t_call_charge_if_there_was_a_purchase_made_the_period_for_a_monthly_subscription" } do
    Feature.activate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, @product.user)
    @subscription.update_flag!(:renewal_disabled_due_to_indian_card_mandate, true, true)

    expect_any_instance_of(Subscription).to receive(:india_card_mandate_reliability_enabled?).and_return(true)
    expect_any_instance_of(Subscription).to receive(:refresh_indian_card_mandate!).and_return("missing")
    expect_any_instance_of(Subscription).not_to receive(:charge!)
    described_class.new.perform(@subscription.id)
    expect(@subscription.reload).to be_alive
  ensure
    Feature.deactivate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, @product.user)
  end

  describe "resuming a membership held on a pending Indian card mandate",
           vcr: { cassette_name: "RecurringChargeWorker/doesn_t_call_charge_if_there_was_a_purchase_made_the_period_for_a_monthly_subscription" } do
    let(:seller) { create(:user) }
    let(:product) { create(:subscription_product, user: seller) }
    let(:merchant_account) do
      create(:merchant_account, user: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id, charge_processor_merchant_id: nil)
    end
    let(:card) { create(:indian_stripe_credit_card, stripe_setup_intent_id: "seti_held") }
    let(:subscription) { create(:subscription, link: product, credit_card: card) }
    let!(:original_purchase) do
      create(:membership_purchase, link: product, subscription:, is_original_subscription_purchase: true, merchant_account:, credit_card: card)
    end
    let(:mail) { instance_double(ActionMailer::MessageDelivery, deliver_later: true) }

    before do
      allow(MerchantAccount).to receive(:gumroad).with(StripeChargeProcessor.charge_processor_id).and_return(merchant_account)
      Feature.activate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)
      Feature.activate_user(Subscription::INDIA_CARD_MANDATE_PENDING_RESTART_FEATURE, seller)
      product.update_column(:price_currency_type, Currency::INR)
      # No signup rate, so the fixing prices off today's rate.
      original_purchase.update_columns(
        displayed_price_currency_type: Currency::INR,
        displayed_price_cents: 80_000,
        price_cents: 10_00,
        total_transaction_cents: 10_00,
        rate_converted_to_usd: nil
      )
      Redis::Namespace.new(:currencies, redis: $redis).set("INR", "80")
      subscription.update!(stripe_mandate_id: "mandate_held", renewal_disabled_due_to_indian_card_mandate: true, indian_card_mandate_hold_pending: true)

      @mandate_status = "active"
      @setup_intent_currency = Currency::INR
      @open_transactions_during_external_calls = []
      record_open_transactions = -> { @open_transactions_during_external_calls << ActiveRecord::Base.connection.open_transactions }
      allow(ChargeProcessor).to receive(:get_mandate) do
        record_open_transactions.call
        Stripe::Mandate.construct_from(id: "mandate_held", status: @mandate_status, payment_method: "pm_pending")
      end
      allow(ChargeProcessor).to receive(:get_setup_intent) do
        record_open_transactions.call
        @on_get_setup_intent&.call
        instance_double(
          StripeSetupIntent,
          mandate: "mandate_held",
          metadata: { gumroad_subscription_id: subscription.external_id },
          card_mandate_options: Stripe::StripeObject.construct_from(currency: @setup_intent_currency)
        )
      end
      allow_any_instance_of(Subscription).to receive(:get_rate).and_wrap_original do |method, *args|
        record_open_transactions.call
        method.call(*args)
      end
      allow(CustomerLowPriorityMailer).to receive(:subscription_indian_card_mandate_invalid).and_return(mail)
      allow(ErrorNotifier).to receive(:notify)
      allow(Rails.logger).to receive(:info).and_call_original
    end

    after do
      Feature.deactivate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)
      Feature.deactivate_user(Subscription::INDIA_CARD_MANDATE_PENDING_RESTART_FEATURE, seller)
    end

    def perform_after_period
      travel_to(subscription.period.from_now + 1.day) do
        described_class.new.perform(subscription.id, true)
      end
    end

    it "records the INR fixing before it charges, outside any transaction around Stripe and the rate lookup" do
      open_transactions_before = ActiveRecord::Base.connection.open_transactions
      fixing_at_charge = nil
      expect_any_instance_of(Subscription).to receive(:charge!) do |charged|
        fixing_at_charge = charged.later_charge_presentments.sole
      end

      perform_after_period

      expect(fixing_at_charge).to have_attributes(
        presentment_currency: Currency::INR,
        presentment_price_cents: 80_000,
        canonical_price_cents: 10_00
      )
      subscription.reload
      expect(subscription).not_to be_renewal_disabled_due_to_indian_card_mandate
      expect(subscription).not_to be_indian_card_mandate_hold_pending
      expect(@open_transactions_during_external_calls.size).to eq(3)
      expect(@open_transactions_during_external_calls).to all(eq(open_transactions_before))
      expect(Rails.logger).to have_received(:info).with("indian_card_mandate.pending_restart.renewal_resumed subscription_id=#{subscription.id} mandate_id=mandate_held")
    end

    it "keeps renewals paused and does not charge when there is no fixing to record" do
      allow_any_instance_of(Subscription).to receive(:get_rate).and_return(nil)
      expect_any_instance_of(Subscription).not_to receive(:charge!)

      perform_after_period

      subscription.reload
      expect(subscription).to be_renewal_disabled_due_to_indian_card_mandate
      expect(subscription).to be_indian_card_mandate_held
      expect(subscription.later_charge_presentments).to be_empty
    end

    it "ends the hold and asks the buyer once for a new card when the bank approved the mandate in USD" do
      @setup_intent_currency = Currency::USD
      expect_any_instance_of(Subscription).not_to receive(:charge!)

      perform_after_period
      perform_after_period

      subscription.reload
      expect(subscription).to be_indian_card_mandate_requires_reauthorization
      expect(subscription.stripe_mandate_id).to be_nil
      expect(subscription).not_to be_indian_card_mandate_held
      expect(subscription).to be_renewal_disabled_due_to_indian_card_mandate
      expect(subscription.later_charge_presentments).to be_empty
      expect(CustomerLowPriorityMailer).to have_received(:subscription_indian_card_mandate_invalid).with(subscription.id).once
      expect(mail).to have_received(:deliver_later).with(queue: "low").once
      expect(ErrorNotifier).to have_received(:notify).with("Held Indian card mandate does not match its setup intent", subscription: subscription.external_id, mandate_id: "mandate_held")
    end

    it "leaves a newer hold alone when the mandate is replaced before the lock" do
      @on_get_setup_intent = -> { Subscription.where(id: subscription.id).update_all(stripe_mandate_id: "mandate_newer") }
      expect_any_instance_of(Subscription).not_to receive(:charge!)

      perform_after_period

      subscription.reload
      expect(subscription.stripe_mandate_id).to eq("mandate_newer")
      expect(subscription).to be_indian_card_mandate_held
      expect(subscription.later_charge_presentments).to be_empty
    end

    it "leaves a newer hold alone when the mandate is replaced before the lock that would end the hold" do
      @setup_intent_currency = Currency::USD
      @on_get_setup_intent = -> { Subscription.where(id: subscription.id).update_all(stripe_mandate_id: "mandate_newer") }
      expect_any_instance_of(Subscription).not_to receive(:charge!)

      perform_after_period

      subscription.reload
      expect(subscription.stripe_mandate_id).to eq("mandate_newer")
      expect(subscription).to be_indian_card_mandate_held
      expect(subscription).not_to be_indian_card_mandate_requires_reauthorization
      expect(CustomerLowPriorityMailer).not_to have_received(:subscription_indian_card_mandate_invalid)
    end

    it "keeps the hold, without charging, while the INR fixing is briefly unavailable" do
      allow_any_instance_of(MerchantAccount).to receive(:settlement_currency_mismatch_active?).and_return(true)
      expect(subscription.indian_card_recovery_presentment_currency).to be_nil
      expect_any_instance_of(Subscription).not_to receive(:charge!)

      perform_after_period

      subscription.reload
      expect(subscription).to be_indian_card_mandate_held
      expect(subscription).not_to be_indian_card_mandate_requires_reauthorization
      expect(subscription.stripe_mandate_id).to eq("mandate_held")
      expect(subscription.later_charge_presentments).to be_empty
      expect(CustomerLowPriorityMailer).not_to have_received(:subscription_indian_card_mandate_invalid)
      expect(ErrorNotifier).to have_received(:notify).with("Held Indian card mandate cannot record its INR fixing yet", subscription: subscription.external_id, mandate_id: "mandate_held")
    end

    it "records the INR fixing before charging a held membership whose free trial ended without a payment" do
      original_purchase.is_free_trial_purchase = true
      original_purchase.update_columns(purchase_state: "not_charged", flags: original_purchase.flags)
      subscription.update_columns(free_trial_ends_at: 1.day.ago)
      expect(subscription.purchases.successful).to be_empty
      fixing_at_charge = nil
      expect_any_instance_of(Subscription).to receive(:charge!) do |charged|
        fixing_at_charge = charged.later_charge_presentments.sole
      end

      perform_after_period

      expect(fixing_at_charge).to have_attributes(
        presentment_currency: Currency::INR,
        presentment_price_cents: 80_000,
        canonical_price_cents: 10_00
      )
      subscription.reload
      expect(subscription).not_to be_renewal_disabled_due_to_indian_card_mandate
      expect(subscription).not_to be_indian_card_mandate_hold_pending
    end

    context "when the product is listed in USD" do
      before do
        product.update_column(:price_currency_type, Currency::USD)
        original_purchase.update_columns(displayed_price_currency_type: Currency::USD, displayed_price_cents: 10_00)
        @setup_intent_currency = Currency::USD
      end

      it "checks the mandate was approved in USD, then resumes and charges without a fixing" do
        expect_any_instance_of(Subscription).to receive(:charge!)

        perform_after_period

        subscription.reload
        expect(subscription).not_to be_renewal_disabled_due_to_indian_card_mandate
        expect(subscription).not_to be_indian_card_mandate_hold_pending
        expect(subscription.later_charge_presentments).to be_empty
        expect(ChargeProcessor).to have_received(:get_setup_intent)
      end

      it "ends the hold when the bank approved the mandate in INR" do
        @setup_intent_currency = Currency::INR
        expect_any_instance_of(Subscription).not_to receive(:charge!)

        perform_after_period

        subscription.reload
        expect(subscription).to be_indian_card_mandate_requires_reauthorization
        expect(subscription).not_to be_indian_card_mandate_held
        expect(subscription.later_charge_presentments).to be_empty
      end
    end

    it "records no INR fixing when a paused membership that was never held recovers" do
      subscription.update!(indian_card_mandate_hold_pending: false)
      expect_any_instance_of(Subscription).to receive(:charge!)

      perform_after_period

      expect(subscription.reload).not_to be_renewal_disabled_due_to_indian_card_mandate
      expect(subscription.later_charge_presentments).to be_empty
      expect(ChargeProcessor).not_to have_received(:get_setup_intent)
    end

    it "leaves an existing price fixing untouched and charges" do
      fixing = create(:later_charge_presentment, owner: subscription, presentment_currency: Currency::INR, presentment_price_cents: 75_000, effective_from: 1.day.ago)
      fixing_attributes = fixing.reload.attributes
      expect_any_instance_of(Subscription).to receive(:charge!)

      perform_after_period

      expect(subscription.reload.later_charge_presentments.to_a).to eq([fixing])
      expect(fixing.reload.attributes).to eq(fixing_attributes)
      expect(subscription).not_to be_renewal_disabled_due_to_indian_card_mandate
    end

    it "tells the buyer once when the bank rejects the held mandate, and ends the hold" do
      @mandate_status = "inactive"
      expect_any_instance_of(Subscription).not_to receive(:charge!)

      perform_after_period
      perform_after_period

      expect(CustomerLowPriorityMailer).to have_received(:subscription_indian_card_mandate_invalid).with(subscription.id).once
      subscription.reload
      expect(subscription).to be_renewal_disabled_due_to_indian_card_mandate
      expect(subscription).not_to be_indian_card_mandate_hold_pending
    end

    it "keeps waiting while the bank is still confirming" do
      @mandate_status = "pending"
      expect_any_instance_of(Subscription).not_to receive(:charge!)

      perform_after_period

      subscription.reload
      expect(subscription).to be_indian_card_mandate_held
      expect(CustomerLowPriorityMailer).not_to have_received(:subscription_indian_card_mandate_invalid)
    end
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

      it "charges after an Indian card mandate recovers",
         vcr: { cassette_name: "RecurringChargeWorker/doesn_t_call_charge_if_there_was_a_purchase_made_the_period_for_a_monthly_subscription" } do
        Feature.activate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, @product.user)
        @subscription.update_flag!(:renewal_disabled_due_to_indian_card_mandate, true, true)
        allow_any_instance_of(Subscription).to receive(:india_card_mandate_reliability_enabled?).and_return(true)
        allow_any_instance_of(Subscription).to receive(:refresh_indian_card_mandate!) do |subscription|
          subscription.update_flag!(:renewal_disabled_due_to_indian_card_mandate, false, true)
          "active"
        end

        travel_to(@subscription.period.from_now + 5.days + 1.minute) do
          expect_any_instance_of(Subscription).not_to receive(:unsubscribe_and_fail!)
          expect_any_instance_of(Subscription).to receive(:charge!)
          described_class.new.perform(@subscription.id, true)
        end
      ensure
        Feature.deactivate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, @product.user)
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

  describe "Indian card subscription has a pending plan change" do
    before do
      seller = create(:user)
      product = create(
        :subscription_product,
        user: seller,
        subscription_duration: BasePrice::Recurrence::QUARTERLY,
        price_cents: 10_00
      )
      quarterly_price = product.prices.find_by!(recurrence: BasePrice::Recurrence::QUARTERLY)
      create(:price, link: product, recurrence: BasePrice::Recurrence::MONTHLY, price_cents: 5_00)
      card = CreditCard.create!(
        charge_processor_id: StripeChargeProcessor.charge_processor_id,
        stripe_customer_id: "cus_plan_change",
        processor_payment_method_id: "pm_plan_change",
        stripe_fingerprint: "fingerprint_plan_change",
        visual: "**** **** **** 4242",
        card_type: CardType::VISA,
        card_country: Compliance::Countries::IND.alpha2,
        expiry_month: 12,
        expiry_year: 2030
      )
      @subscription = create(:subscription, link: product, credit_card: card, price: quarterly_price)
      merchant_account = create(
        :merchant_account,
        user: nil,
        charge_processor_id: StripeChargeProcessor.charge_processor_id,
        charge_processor_merchant_id: nil
      )
      original_purchase = create(
        :membership_purchase,
        link: product,
        subscription: @subscription,
        price: quarterly_price,
        price_cents: quarterly_price.price_cents,
        is_original_subscription_purchase: true,
        merchant_account:
      )
      original_purchase.update_columns(credit_card_id: card.id, created_at: 4.months.ago, succeeded_at: 4.months.ago)
      @plan_change = create(
        :subscription_plan_change,
        subscription: @subscription,
        tier: nil,
        recurrence: BasePrice::Recurrence::MONTHLY,
        perceived_price_cents: 5_00
      )
      @subscription.update!(stripe_mandate_id: "mandate_old_plan")
      Feature.activate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)
      allow_any_instance_of(Subscription).to receive(:india_card_mandate_reliability_enabled?).and_return(true)
      allow_any_instance_of(Subscription).to receive(:indian_card_mandate_terms) do |current_subscription|
        { amount: 10_00, currency: Currency::USD, interval: current_subscription.recurrence, interval_count: 1 }
      end
    end

    after do
      Feature.deactivate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, @subscription.seller)
    end

    it "requires a new mandate before it charges the new plan",
       vcr: { cassette_name: "RecurringChargeWorker/subscription_has_a_pending_plan_change/updates_the_variants_and_prices_before_charging" } do
      expect do
        described_class.new.perform(@subscription.id)
      end.not_to change { @subscription.purchases.not_is_original_subscription_purchase.not_is_archived_original_subscription_purchase.count }

      expect(@plan_change.reload).to be_applied
      expect(@subscription.reload).to be_renewal_disabled_due_to_indian_card_mandate
      expect(@subscription).to be_indian_card_mandate_requires_reauthorization
      expect(@subscription.stripe_mandate_id).to be_nil
    end

    it "rolls back the plan when mandate-safe plan cleanup fails",
       vcr: { cassette_name: "RecurringChargeWorker/subscription_has_a_pending_plan_change/updates_the_variants_and_prices_before_charging" } do
      allow_any_instance_of(SubscriptionPlanChange).to receive(:mark_deleted!).and_raise("plan cleanup failed")

      expect do
        described_class.new.perform(@subscription.id)
      end.to raise_error(RuntimeError, "plan cleanup failed")

      expect(@plan_change.reload).not_to be_applied
      expect(@subscription.reload.recurrence).to eq(BasePrice::Recurrence::QUARTERLY)
      expect(@subscription).not_to be_renewal_disabled_due_to_indian_card_mandate
      expect(@subscription.stripe_mandate_id).to eq("mandate_old_plan")
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

  context "installment plan with a standing chargeback on every installment" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, :with_installment_plan, user: seller) }
    let(:buyer) { create(:user, credit_card: create(:credit_card)) }
    let(:subscription) do
      create(:subscription, user: buyer, link: product, is_installment_plan: true,
                            charge_occurrence_count: 3, cancelled_at: nil)
    end

    # Paid installments, all in the past so the period check does not mask the guard.
    def create_installment(chargedback:, original:, created_at:)
      create(:purchase, link: product, seller:, purchaser: buyer, subscription:,
                        is_original_subscription_purchase: original,
                        purchase_state: "successful",
                        chargeback_date: chargedback ? 1.day.ago : nil,
                        created_at:)
    end

    it "does not charge when every installment is charged back" do
      create_installment(chargedback: true, original: true,  created_at: 3.months.ago)
      create_installment(chargedback: true, original: false, created_at: 2.months.ago)

      expect_any_instance_of(Subscription).to_not receive(:charge!)
      described_class.new.perform(subscription.id)
    end

    # A single disputed installment can be a reversible mistake; blocking those would strand
    # plans whose buyer still intends to pay.
    it "still charges when only some installments are charged back" do
      create_installment(chargedback: true,  original: true,  created_at: 3.months.ago)
      create_installment(chargedback: false, original: false, created_at: 2.months.ago)

      expect_any_instance_of(Subscription).to receive(:charge!)
      described_class.new.perform(subscription.id)
    end

    # A won dispute must let the plan resume without anyone re-enabling it by hand.
    it "charges again once the chargebacks are reversed" do
      create_installment(chargedback: true, original: true,  created_at: 3.months.ago)
      create_installment(chargedback: true, original: false, created_at: 2.months.ago)
      # Set the flag rather than assigning `flags` wholesale: flags is a bitfield that also
      # carries is_original_subscription_purchase, and overwriting it detaches the original
      # purchase, which makes the subscription unpriceable rather than testing anything.
      subscription.purchases.each { _1.update!(chargeback_reversed: true) }

      expect_any_instance_of(Subscription).to receive(:charge!)
      described_class.new.perform(subscription.id)
    end

    # The guard is scoped to installment plans: a recurring membership has a working
    # cancellation path (widened by #6568) and must not be silently frozen instead.
    it "does not apply to a recurring subscription whose charges are all disputed" do
      recurring = create(:subscription, user: buyer, link: @product)
      create(:purchase, link: @product, subscription: recurring, purchase_state: "successful",
                        is_original_subscription_purchase: true, chargeback_date: 1.day.ago,
                        created_at: 3.months.ago)

      expect(recurring.all_charges_disputed?).to eq(false)
    end
  end
end
