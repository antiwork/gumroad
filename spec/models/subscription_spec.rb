# frozen_string_literal: true

require "spec_helper"

describe Subscription, :vcr do
  include CurrencyHelper
  include ManageSubscriptionHelpers

  let(:seller) { create(:user) }

  before do
    @product = create(:subscription_product, user: seller, is_licensed: true)
    @subscription = create(:subscription, user: create(:user), link: @product)
    @purchase = create(:purchase, link: @product, email: @subscription.user.email, full_name: "squiddy",
                                  price_cents: @product.price_cents, is_original_subscription_purchase: true,
                                  subscription: @subscription, created_at: 2.days.ago)
  end

  describe "associations" do
    describe "#latest_plan_change" do
      it "returns the most recent, live plan change" do
        create(:subscription_plan_change, subscription: @subscription, created_at: 1.month.ago)
        most_recent = create(:subscription_plan_change, subscription: @subscription, created_at: 1.day.ago)
        create(:subscription_plan_change, subscription: @subscription, created_at: 1.week.ago)
        create(:subscription_plan_change, subscription: @subscription, created_at: 1.hour.ago, deleted_at: Time.current)

        expect(@subscription.latest_plan_change).to eq most_recent
      end
    end

    describe "#latest_applicable_plan_change" do
      it "returns the most recent, live plan change that is applicable" do
        create(:subscription_plan_change, subscription: @subscription, created_at: 2.weeks.ago, deleted_at: 1.week.ago)
        create(:subscription_plan_change, subscription: @subscription, created_at: 10.days.ago, applied: true)

        create(:subscription_plan_change, subscription: @subscription, created_at: 5.days.ago, for_product_price_change: true, effective_on: 1.week.from_now)
        create(:subscription_plan_change, subscription: @subscription, created_at: 4.days.ago, for_product_price_change: true, effective_on: 2.days.ago, notified_subscriber_at: nil)
        create(:subscription_plan_change, subscription: @subscription, created_at: 3.days.ago, for_product_price_change: true, effective_on: 1.day.ago, notified_subscriber_at: 1.day.ago, deleted_at: 12.hours.ago)
        create(:subscription_plan_change, subscription: @subscription, created_at: 2.days.ago, for_product_price_change: true, effective_on: 1.day.ago, notified_subscriber_at: 1.day.ago, applied: true)

        most_recent = create(:subscription_plan_change, subscription: @subscription, created_at: 1.day.ago, for_product_price_change: true, effective_on: 1.day.ago, notified_subscriber_at: 1.day.ago)

        expect(@subscription.latest_applicable_plan_change).to eq most_recent
      end
    end
  end

  describe "lifecycle hooks" do
    describe "create_interruption_event", :freeze_time do
      it "records a deactivated event if deactivated_at is set and was previously blank" do
        first_deactivation = 1.week.ago
        expect do
          @subscription.update!(deactivated_at: first_deactivation)
          expect(@subscription.reload.subscription_events.deactivated.last.occurred_at).to eq first_deactivation
        end.to change { @subscription.reload.subscription_events.deactivated.count }.from(0).to(1)

        expect do
          @subscription.update!(deactivated_at: Time.current)
          expect(@subscription.reload.subscription_events.deactivated.last.occurred_at).to eq first_deactivation
        end.not_to change { @subscription.reload.subscription_events.deactivated.count }

        expect do
          create(:subscription, deactivated_at: Time.current)
        end.to change { SubscriptionEvent.deactivated.count }.from(1).to(2)
      end

      it "records a restarted event if deactivated_at is cleared" do
        @subscription.update!(deactivated_at: Time.current)
        expect do
          @subscription.update!(deactivated_at: nil)
          expect(@subscription.reload.subscription_events.restarted.last.occurred_at).to eq Time.current
        end.to change { @subscription.reload.subscription_events.restarted.count }.from(0).to(1)
      end

      it "does nothing if deactivated_at has not changed" do
        expect do
          @subscription.update!(failed_at: Time.current)
        end.not_to change { @subscription.reload.subscription_events.count }
      end
    end

    describe "send_ended_notification_webhook" do
      it "sends a 'subscription_ended' notification if the subscription has just been deactivated" do
        @subscription.update!(deactivated_at: Time.current)
        expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(nil, nil, ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME, @subscription.id)
      end

      it "does not send a 'subscription_ended' notification if the subscription was already deactivated" do
        @subscription.update!(deactivated_at: Time.current)
        Sidekiq::Worker.clear_all

        @subscription.update!(deactivated_at: Time.current)
        expect(PostToPingEndpointsWorker).not_to have_enqueued_sidekiq_job(nil, nil, ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME, @subscription.id)
      end

      it "does not send a 'subscription_ended' notification if the subscription is not deactivated" do
        @subscription.update!(cancelled_at: Time.current)
        expect(PostToPingEndpointsWorker).not_to have_enqueued_sidekiq_job(nil, nil, ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME, @subscription.id)
      end
    end

    describe "creation" do
      it "sets the seller" do
        expect(@subscription.seller).to eq(@purchase.seller)
      end
    end
  end

  describe "scopes" do
    describe ".active_without_pending_cancel" do
      subject { described_class.active_without_pending_cancel }

      it "returns only active subscriptions" do
        is_expected.to contain_exactly(@subscription)
      end

      context "when subscription is a test" do
        before do
          @subscription.update!(is_test_subscription: true)
        end

        it { is_expected.to be_empty }
      end

      context "when subscription has failed" do
        before do
          @subscription.update!(failed_at: 1.minute.ago)
        end

        it { is_expected.to be_empty }
      end

      context "when subscription has ended" do
        before do
          @subscription.update!(ended_at: 1.minute.ago)
        end

        it { is_expected.to be_empty }
      end

      context "when subscription was cancelled" do
        before do
          @subscription.update!(cancelled_at: 1.minute.ago)
        end

        it { is_expected.to be_empty }
      end

      context "when subscription is pending cancellation" do
        before do
          @subscription.update!(cancelled_at: 1.minute.from_now)
        end

        it { is_expected.to be_empty }
      end
    end
  end

  describe "#as_json" do
    it "returns the expected JSON representation" do
      expected = {
        id: @subscription.external_id,
        email: @subscription.email,
        product_id: @subscription.link.external_id,
        product_name: @subscription.link.name,
        user_id: @subscription.user.external_id,
        user_email: @subscription.user.email,
        purchase_ids: @subscription.purchases.map(&:external_id),
        created_at: @subscription.created_at,
        cancelled_at: @subscription.cancelled_at,
        user_requested_cancellation_at: @subscription.user_requested_cancellation_at,
        charge_occurrence_count: @subscription.charge_occurrence_count,
        recurrence: @subscription.recurrence,
        ended_at: @subscription.ended_at,
        failed_at: @subscription.failed_at,
        free_trial_ends_at: @subscription.free_trial_ends_at,
        status: @subscription.status
      }

      expect(@subscription.as_json).to eq(expected)
    end

    it "excludes 'not_charged' plan change purchases" do
      purchase = create(:purchase, link: @product, subscription: @subscription, purchase_state: "not_charged")
      expect(@subscription.as_json[:purchase_ids]).not_to include purchase.external_id
    end

    it "excludes failed purchases" do
      failed_purchase = create(:failed_purchase, link: @product, subscription: @subscription)
      expect(@subscription.as_json[:purchase_ids]).not_to include failed_purchase.external_id
    end

    it "includes free trial 'not_charged' purchases" do
      purchase = create(:free_trial_membership_purchase)
      expect(purchase.subscription.as_json[:purchase_ids]).to eq [purchase.external_id]
    end

    it "includes license_key for membership products with licensing enabled" do
      license = create(:license, link: @product, purchase: @purchase)

      expect(@subscription.as_json[:license_key]).to eq license.serial
    end
  end

  describe "#subscription_mobile_json_data" do
    before do
      travel_to Time.current
      @product = create(:subscription_product, user: create(:user))
      @user = create(:user, credit_card: create(:credit_card))
      @very_old_installment = create(:installment, name: "very old installment", link: @product, created_at: 5.months.ago, published_at: 5.months.ago)
      @old_installment = create(:installment, name: "old installment", link: @product, created_at: 4.months.ago, published_at: 4.months.ago)
      @new_installment = create(:installment, name: "new installment", link: @product, created_at: Time.current, published_at: Time.current)
      @unpublished_installment = create(:installment, link: @product, published_at: nil)

      @workflow = create(:workflow, seller: @product.user, link: @product, created_at: 13.months.ago, published_at: 13.months.ago)
      @workflow_installment = create(:installment, name: "workflow installment", link: @product, workflow: @workflow, published_at: 13.months.ago)
      @workflow_installment_rule = create(:installment_rule, installment: @workflow_installment, delayed_delivery_time: 1.day)

      @subscription = create(:subscription, link: @product, user: @user, created_at: 1.year.ago)
      @purchase = create(:purchase, is_original_subscription_purchase: true, link: @product, subscription: @subscription, purchaser: @user, created_at: @subscription.created_at)
    end

    it "returns nothing if the subscription is no longer alive" do
      @subscription.cancel_effective_immediately!
      expect(@subscription.subscription_mobile_json_data).to eq nil
    end

    it "returns the correct json format for the mobile api" do
      create(:creator_contacting_customers_email_info, purchase: @purchase, installment: @workflow_installment)
      create(:creator_contacting_customers_email_info, purchase: @purchase, installment: @very_old_installment)
      create(:creator_contacting_customers_email_info, purchase: @purchase, installment: @old_installment)
      create(:creator_contacting_customers_email_info, purchase: @purchase, installment: @new_installment)
      [@subscription, @purchase, @product].each(&:reload)
      subscription_mobile_json_data = @subscription.subscription_mobile_json_data.to_json
      expected_subscription_data = @product.as_json(mobile: true)
      subscription_data = {
        subscribed_at: @subscription.created_at,
        external_id: @subscription.external_id,
        recurring_amount: @subscription.original_purchase.formatted_display_price
      }
      expected_subscription_data[:subscription_data] = subscription_data
      expected_subscription_data[:purchase_id] = @purchase.external_id
      expected_subscription_data[:purchased_at] = @purchase.created_at
      expected_subscription_data[:user_id] = @purchase.purchaser.external_id
      expected_subscription_data[:can_contact] = @purchase.can_contact
      expected_subscription_data[:updates_data] = @subscription.updates_mobile_json_data
      expect(@subscription.subscription_mobile_json_data[:updates_data].length).to eq 4
      expected_updates_data = [
        @workflow_installment.installment_mobile_json_data(purchase: @purchase, subscription: @subscription),
        @very_old_installment.installment_mobile_json_data(purchase: @purchase, subscription: @subscription),
        @old_installment.installment_mobile_json_data(purchase: @purchase, subscription: @subscription),
        @new_installment.installment_mobile_json_data(purchase: @purchase, subscription: @subscription)
      ]
      expect(@subscription.subscription_mobile_json_data[:updates_data].sort_by { |h| h[:name] }.to_json).to eq expected_updates_data.sort_by { |h| h[:name] }.to_json
      expect(subscription_mobile_json_data).to eq expected_subscription_data.to_json
    end

    it "includes the first installment for new subscribers if the creator set should_include_last_post to true" do
      product = create(:membership_product)
      product.should_include_last_post = true
      product.save!
      user = create(:user)
      installment = create(:installment, link: product, published_at: 1.day.ago)
      subscription = create(:subscription, link: product, user:)
      purchase = create(:purchase, is_original_subscription_purchase: true, link: product, subscription:, purchaser: user)
      create(:creator_contacting_customers_email_info, purchase:, installment:)
      expect(subscription.updates_mobile_json_data.length).to eq 1
      expect(subscription.updates_mobile_json_data.first[:external_id]).to eq installment.external_id
    end
  end

  describe "#credit_card_to_charge" do
    context "when test subscription" do
      it "returns nil" do
        user = create(:user, credit_card: create(:credit_card))
        product = create(:subscription_product, user:)
        subscription = create(:subscription, link: product, user:, is_test_subscription: true)

        expect(subscription.credit_card_to_charge).to be_nil
      end
    end

    context "when guest subscription purchase" do
      it "returns the credit card used with the original purchase" do
        user = create(:user)
        product = create(:subscription_product, user:)
        original_purchase_card = create(:credit_card)
        subscription = create(:subscription, link: product, user: nil, credit_card: original_purchase_card)

        expect(subscription.credit_card_to_charge).to eq(original_purchase_card)
      end
    end

    context "when user has a card saved on file and doesn't have a card in the purchase" do
      it "returns the card saved on file, not the card used during purchase" do
        buyers_card = create(:credit_card)
        user = create(:user, credit_card: buyers_card)
        product = create(:subscription_product, user:)
        subscription = create(:subscription, link: product, user:)

        expect(subscription.credit_card_to_charge).to eq(buyers_card)
      end
    end

    context "when user has a card associated to the subscription" do
      it "returns the subscription's card" do
        buyers_card = create(:credit_card)
        subscription_card = create(:credit_card)
        user = create(:user, credit_card: buyers_card)
        product = create(:subscription_product, user:)
        subscription = create(:subscription, link: product, user:, credit_card: subscription_card)

        expect(subscription.credit_card_to_charge).to eq(subscription_card)
      end
    end
  end

  describe "#installments" do
    before do
      @product = create(:subscription_product, user: create(:user))
      @user = create(:user, credit_card: create(:credit_card))
      @subscription = create(:subscription, link: @product, user: @user, created_at: 3.days.ago)
      @purchase = create(:purchase, is_original_subscription_purchase: true, link: @product, subscription: @subscription, purchaser: @user)
      @very_old_installment = create(:installment, link: @product, created_at: 5.months.ago, published_at: 5.months.ago)
      @old_installment = create(:installment, link: @product, created_at: 4.months.ago, published_at: 4.months.ago)
      @new_installment = create(:installment, link: @product, published_at: Time.current)
      @unpublished_installment = create(:installment, link: @product, published_at: nil)
    end

    it "returns the installments made after subscription created, plus the last one made before the subscription if link option is set" do
      @product.update_attribute(:should_include_last_post, true)
      expect(@subscription.installments).to eq [@old_installment, @new_installment]
    end

    it "returns the installments made after subscription created, plus the last one made before the subscription if link option is set, ordered with published_at date" do
      @product.update_attribute(:should_include_last_post, true)
      old_installment1 = create(:installment, link: @product, published_at: 4.days.ago)
      create(:installment, link: @product, published_at: 5.days.ago)
      expect(@subscription.installments).to eq [old_installment1, @new_installment]
    end

    it "returns the installments made after subscription created without the last one made before the subscription if link option is not set" do
      expect(@subscription.installments).to eq [@new_installment]
    end

    it "does not include unpublished installments" do
      expect(@subscription.installments).to_not include @unpublished_installment
    end

    it "does not include any installment older than the last installment before the creation of the subscription" do
      expect(@subscription.installments).to_not include @very_old_installment
    end

    describe "cancelled subscriptions" do
      before do
        @product = create(:subscription_product, user: create(:user), is_recurring_billing: true)
        @user = create(:user, credit_card: create(:credit_card))
        @subscription = create(:subscription, link: @product, user: @user, created_at: 5.months.ago, cancelled_at: 3.months.ago)
        @purchase = create(:purchase, is_original_subscription_purchase: true, link: @product, subscription: @subscription, purchaser: @user)
        @very_old_installment = create(:installment, link: @product, created_at: 7.months.ago, published_at: 7.months.ago)
        @old_installment = create(:installment, link: @product, created_at: 6.months.ago, published_at: 6.months.ago)
        @correct_installment = create(:installment, link: @product, created_at: 4.months.ago, published_at: 4.months.ago)
        @current_installment = create(:installment, link: @product, created_at: Time.current, published_at: Time.current)
      end

      it "returns installment created while subscription active, plus the last installment before the subscription was created" do
        expect(@subscription.installments).to eq [@correct_installment]
      end

      it "does not include any installment older than the last installment before the creation of the subscription if link option is set" do
        @product.update_attribute(:should_include_last_post, true)
        expect(@subscription.installments).to_not include @very_old_installment
        expect(@subscription.installments).to include @old_installment
      end

      it "does not include any past installments if link option is not set" do
        expect(@subscription.installments).to_not include @old_installment
      end

      it "does not return installments created after subscription cancelled" do
        expect(@subscription.installments).to_not include @current_installment
      end
    end

    describe "failed subscriptions" do
      before do
        @product = create(:subscription_product, user: create(:user), is_recurring_billing: true)
        @user = create(:user, credit_card: create(:credit_card))
        @subscription = create(:subscription, link: @product, user: @user, created_at: 5.months.ago, failed_at: 3.months.ago)
        @purchase = create(:purchase, is_original_subscription_purchase: true, link: @product, subscription: @subscription, purchaser: @user)
        @old_installment = create(:installment, link: @product, created_at: 6.months.ago, published_at: 6.months.ago)
        @very_old_installment = create(:installment, link: @product, created_at: 7.months.ago, published_at: 7.months.ago)
        @correct_installment = create(:installment, link: @product, created_at: 4.months.ago, published_at: 4.months.ago)
        @end_of_month_failed = create(:installment, link: @product, created_at: 3.months.ago.at_end_of_month, published_at: 3.months.ago.at_end_of_month)
        @current_installment = create(:installment, link: @product, created_at: Time.current, published_at: Time.current)
      end

      it "returns installment created while subscription active, plus the last installment before the subscription was created if link option is set" do
        @product.update_attribute(:should_include_last_post, true)
        expect(@subscription.installments).to eq [@old_installment, @correct_installment]
      end

      it "returns only the installment created while subscription active if link option is not set" do
        expect(@subscription.installments).to eq [@correct_installment]
      end

      it "does not include any installment older than the last installment before the creation of the subscription" do
        expect(@subscription.installments).to_not include @very_old_installment
      end

      it "does not return installment created in the month that subscription failed" do
        expect(@subscription.installments).to_not include @end_of_month_cancelled
      end

      it "does not return installments created after subscription failed" do
        expect(@subscription.installments).to_not include @current_installment
      end
    end

    describe "workflow installments" do
      before do
        @product = create(:subscription_product, user: create(:user), is_recurring_billing: true)
        @user = create(:user, credit_card: create(:credit_card))
        @workflow = create(:workflow, seller: @product.user, link: @product, published_at: 1.week.ago)
        @workflow_installment = create(:installment, link: @product, workflow: @workflow, published_at: Time.current)
        @workflow_installment_rule = create(:installment_rule, installment: @workflow_installment, delayed_delivery_time: 1.day)
        @subscription = create(:subscription, link: @product, user: @user, created_at: 5.months.ago, failed_at: 3.months.ago)
        @purchase = create(:purchase, is_original_subscription_purchase: true, link: @product, subscription: @subscription, purchaser: @user)
      end

      it "does not include any workflow installment" do
        expect(@subscription.installments.length).to eq 0
      end
    end
  end

  describe "#charge!" do
    before do
      @subscription.user.update!(credit_card: create(:credit_card))
    end

    it "creates a new purchase row", :vcr do
      expect do
        @subscription.charge!
      end.to change { Purchase.count }.by(1)
    end

    it "gives new purchase right attributes", :vcr do
      @new_purchase = @subscription.charge!

      expect(@new_purchase.purchase_state).to eq "successful"
      expect(@new_purchase.subscription).to eq @subscription
      expect(@new_purchase.link).to eq @product
      expect(@new_purchase.email).to eq @purchase.email
      expect(@new_purchase.full_name).to eq @purchase.full_name
      expect(@new_purchase.ip_address).to eq @purchase.ip_address
      expect(@new_purchase.ip_country).to eq @purchase.ip_country
      expect(@new_purchase.ip_state).to eq @purchase.ip_state
      expect(@new_purchase.referrer).to eq @purchase.referrer
      expect(@new_purchase.browser_guid).to eq @purchase.browser_guid
      expect(@new_purchase.is_original_subscription_purchase).to be(false)
      expect(@new_purchase.price_cents).to eq @product.price_cents
    end

    it "charges stripe", :vcr do
      @subscription.charge!
    end

    it "creates a purchase event", :vcr do
      create(:event, purchase_id: @purchase.id, email: @purchase.email)
      recurring_purchase = @subscription.charge!
      purchase_event = Event.last
      expect(purchase_event.is_recurring_subscription_charge).to be(true)
      expect(purchase_event.purchase_id).to eq recurring_purchase.id
      expect(purchase_event.email).to eq @purchase.email
    end

    it "uses the previously saved payment instrument to charge an unregistered user's subscription" do
      discover_cc = CreditCard.create(build(:chargeable, card: StripePaymentMethodHelper.success_discover))
      subscription = nil
      travel_to(1.month.ago) do
        subscription = create(:subscription, user: nil, link: @product, credit_card: discover_cc)
        create(:purchase, is_original_subscription_purchase: true, link: @product, subscription:,
                          credit_card: discover_cc)
      end

      expect { subscription.charge! }.to change { Purchase.count }.by(1)

      subscription.reload
      latest_purchase = Purchase.last
      expect(latest_purchase.purchase_state).to eq "successful"
      expect(latest_purchase.card_visual).to eq "**** **** **** 9424"
      expect(subscription.credit_card).to eq(discover_cc)
      expect(subscription.credit_card).to eq(latest_purchase.credit_card)
    end

    it "uses the previously saved payment instrument to charge a registered user's subscription", :vcr do
      user = create(:user)
      discover_cc = CreditCard.create(build(:chargeable, card: StripePaymentMethodHelper.success_discover))
      user.credit_card = discover_cc
      user.save!

      subscription = nil
      travel_to(1.month.ago) do
        subscription = create(:subscription, user:, link: @product, credit_card: discover_cc)
        create(:purchase, is_original_subscription_purchase: true, link: @product, subscription:,
                          credit_card: discover_cc)
      end

      expect { subscription.charge! }.to change { Purchase.count }.by(1)

      subscription.reload
      latest_purchase = Purchase.last
      expect(latest_purchase.purchase_state).to eq "successful"
      expect(latest_purchase.card_visual).to eq "**** **** **** 9424"
      expect(subscription.credit_card).to eq(discover_cc)
      expect(subscription.credit_card).to eq(latest_purchase.credit_card)
    end

    it "uses the payment instrument attached to the subscription in case the purchaser account does not have a saved payment instrument", :vcr do
      user = create(:user)
      discover_cc = CreditCard.create(build(:chargeable, card: StripePaymentMethodHelper.success_discover), nil, user)

      subscription = nil
      travel_to(1.month.ago) do
        subscription = create(:subscription, user:, link: @product, credit_card: discover_cc)
        create(:purchase, is_original_subscription_purchase: true, link: @product, subscription:,
                          credit_card: discover_cc)
      end

      expect { subscription.charge! }.to change { Purchase.count }.by(1)

      subscription.reload
      latest_purchase = Purchase.last
      expect(latest_purchase.purchase_state).to eq "successful"
      expect(latest_purchase.card_visual).to eq "**** **** **** 9424"
      expect(subscription.credit_card).to eq(discover_cc)
      expect(subscription.credit_card).to eq(latest_purchase.credit_card)
    end

    context "with an Indian credit card", :vcr do
      let(:buyer) { create(:user) }
      let(:indian_cc) do
        chargeable = build(:chargeable, card:)
        card = CreditCard.create(chargeable, nil, buyer)
        card.update!(card_params)
        card
      end
      let(:product) do
        create(:membership_product_with_preset_tiered_pricing, recurrence_price_values: [
                 { "monthly": { enabled: true, price: 5 } },
                 { "monthly": { enabled: true, price: 8 } }
               ])
      end
      let(:subscription) { create(:subscription, link: product, user: buyer, credit_card: indian_cc) }
      before do create(:membership_purchase, is_original_subscription_purchase: true, link: product, variant_attributes: [product.default_tier],
                                             price_cents: 5_00, subscription:, purchaser: buyer, credit_card: indian_cc) end

      context "with a successful mandate" do
        let(:card) { StripePaymentMethodHelper.success_indian_card_mandate }
        let(:card_params) do
          {
            json_data: { stripe_payment_intent_id: "pi_2ORMJC9e1RjUNIyY1XR51HRc" },
            processor_payment_method_id: "pm_0ORMJA9e1RjUNIyYs4aGjcbm",
            stripe_customer_id: "cus_PFs3vfBTEQUdma",
          }
        end

        it "uses the mandate associated with the saved credit card to successfully charge" do
          expect { subscription.charge! }.to change { Purchase.count }.by(1)

          subscription.reload
          latest_purchase = Purchase.last

          expect(latest_purchase.purchase_state).to eq "in_progress"
          expect(subscription.credit_card).to eq(indian_cc)
          expect(subscription.credit_card).to eq(latest_purchase.credit_card)
        end
      end

      context "with a cancelled mandate" do
        let(:card) { StripePaymentMethodHelper.cancelled_indian_card_mandate }
        let(:card_params) do
          {
            json_data: { stripe_payment_intent_id: "pi_2OToWV9e1RjUNIyY0BJU6iP9" },
            processor_payment_method_id: "pm_0OToWS9e1RjUNIyYX1ywIsIy",
            stripe_customer_id: "cus_PIPLGhezunZeyY",
          }
        end

        it "uses the mandate associated with the saved credit card and fails" do
          expect { subscription.charge! }.to change { Purchase.count }.by(1)

          subscription.reload
          latest_purchase = Purchase.last
          expect(latest_purchase.purchase_state).to eq "failed"
          expect(latest_purchase.stripe_error_code).to eq "india_recurring_payment_mandate_canceled"
          expect(subscription.credit_card).to eq(indian_cc)
          expect(subscription.credit_card).to eq(latest_purchase.credit_card)
        end
      end
    end

    it "uses the payment instrument attached to the subscription in case the purchaser account's saved payment instrument is not supported by this creator", :vcr do
      user = create(:user)
      native_paypal_card = CreditCard.create(build(:native_paypal_chargeable), nil, user)
      user.credit_card = native_paypal_card
      user.save!

      discover_cc = CreditCard.create(build(:chargeable, card: StripePaymentMethodHelper.success_discover), nil, user)
      subscription = nil
      travel_to(1.month.ago) do
        subscription = create(:subscription, user:, link: @product, credit_card: discover_cc)
        create(:purchase, is_original_subscription_purchase: true, link: @product, subscription:,
                          credit_card: discover_cc)
      end

      expect { subscription.charge! }.to change { Purchase.count }.by(1)

      subscription.reload
      expect(subscription.purchases.count).to eq 2
      latest_purchase = subscription.purchases.last
      expect(latest_purchase.purchase_state).to eq "successful"
      expect(latest_purchase.card_visual).to eq "**** **** **** 9424"
      expect(subscription.credit_card).to eq(discover_cc)
      expect(subscription.credit_card).to eq(latest_purchase.credit_card)

      travel_to(1.month.from_now) do
        # Creator adds support for native paypal payments
        create(:merchant_account_paypal, user: @product.user, charge_processor_merchant_id: "CJS32DZ7NDN5L", currency: "gbp")

        expect { subscription.charge! }.to change { Purchase.count }.by(1)

        subscription.reload
        expect(subscription.purchases.count).to eq 3
        latest_purchase = subscription.purchases.last
        expect(latest_purchase.purchase_state).to eq "successful"
        expect(latest_purchase.credit_card).to eq(discover_cc)
      end
    end

    it "transfers VAT ID and elected tax country from the original purchase to recurring charge" do
      create(:zip_tax_rate, country: "IT", zip_code: nil, state: nil, combined_rate: 0.22, is_seller_responsible: false)

      subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @product)
      original_purchase = build(:purchase, is_original_subscription_purchase: true, link: @product,
                                           subscription:, chargeable: build(:chargeable), purchase_state: "in_progress",
                                           full_name: "gum stein", ip_address: "2.47.255.255", country: "Italy", created_at: 2.days.ago)
      original_purchase.business_vat_id = "IE6388047V"
      original_purchase.process!
      expect(original_purchase.reload.gumroad_tax_cents).to eq 0

      subscription.charge!
      charge_purchase = subscription.reload.purchases.last
      expect(charge_purchase.purchase_state).to eq "successful"
      expect(charge_purchase.purchase_sales_tax_info.business_vat_id).to eq "IE6388047V"
      expect(charge_purchase.total_transaction_cents).to eq original_purchase.total_transaction_cents
      expect(charge_purchase.gumroad_tax_cents).to eq 0
    end

    it "transfers VAT ID from the original purchase's tax refund to recurring charge" do
      create(:zip_tax_rate, country: "IT", zip_code: nil, state: nil, combined_rate: 0.22, is_seller_responsible: false)

      subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @product)
      original_purchase = create(:purchase, is_original_subscription_purchase: true, link: @product,
                                            subscription:, chargeable: build(:chargeable), purchase_state: "in_progress",
                                            full_name: "gum stein", ip_address: "2.47.255.255", country: "Italy", created_at: 2.days.ago)
      original_purchase.process!(off_session: false)
      expect(original_purchase.gumroad_tax_cents).to eq 22
      original_purchase.refund_gumroad_taxes!(refunding_user_id: @product.user.id, note: "Sample Note", business_vat_id: "IE6388047V")

      subscription.charge!
      charge_purchase = subscription.reload.purchases.last
      expect(charge_purchase.purchase_state).to eq "successful"
      expect(charge_purchase.purchase_sales_tax_info.business_vat_id).to eq "IE6388047V"
      expect(charge_purchase.gumroad_tax_cents).to eq 0
    end

    describe "handling of unexpected errors", :vcr do
      context "when a rate limit error occurs" do
        it "does not leave the purchase in in_progress state" do
          expect do
            expect do
              expect do
                expect(Stripe::PaymentIntent).to receive(:create).and_raise(Stripe::RateLimitError)
                @subscription.charge!
              end.to raise_error(ChargeProcessorError)
            end.to change { Purchase.failed.count }.by(1)
          end.not_to change { Purchase.in_progress.count }
        end
      end

      context "when a generic Stripeerror occurs" do
        it "does not leave the purchase in in_progress state" do
          expect do
            expect(Stripe::PaymentIntent).to receive(:create).and_raise(Stripe::IdempotencyError)
            purchase = @subscription.charge!
            expect(purchase.purchase_state).to eq("failed")
          end.not_to change { Purchase.in_progress.count }
        end
      end

      context "when a generic Braintree error occurs" do
        before do
          paypal_card = CreditCard.create(build(:paypal_chargeable), nil, @subscription.user)
          @subscription.user.credit_card = paypal_card
          @subscription.user.save!
        end

        it "does not leave the purchase in in_progress state" do
          expect do
            expect(Braintree::Transaction).to receive(:sale).and_raise(Braintree::BraintreeError)
            purchase = @subscription.charge!
            expect(purchase.purchase_state).to eq("failed")
          end.not_to change { Purchase.in_progress.count }
        end
      end

      context "when a PayPal connection error occurs" do
        before do
          native_paypal_card = CreditCard.create(build(:native_paypal_chargeable), nil, @subscription.user)
          @subscription.user.credit_card = native_paypal_card
          @subscription.user.save!
        end

        it "does not leave the purchase in in_progress state" do
          create(:merchant_account_paypal, user: @subscription.link.user, charge_processor_merchant_id: "CJS32DZ7NDN5L", currency: "gbp")

          expect do
            expect_any_instance_of(PayPal::PayPalHttpClient).to receive(:execute).and_raise(PayPalHttp::HttpError.new(418, OpenStruct.new(details: [OpenStruct.new(description: "IO Error")]), nil))
            purchase = @subscription.charge!
            expect(purchase.purchase_state).to eq("failed")
          end.not_to change { Purchase.in_progress.count }
        end
      end

      context "when unexpected runtime error occurs mid purchase" do
        it "does not leave the purchase in in_progress state" do
          expect do
            expect do
              expect do
                expect_any_instance_of(Purchase).to receive(:charge!).and_raise(RuntimeError)
                @subscription.charge!
              end.to raise_error(RuntimeError)
            end.to change { Purchase.failed.count }.by(1)
          end.not_to change { Purchase.in_progress.count }
        end
      end
    end

    describe "iffy zipcode authorization" do
      it "does not call iffy on recurring charges", :vcr do
        user = @subscription.user
        user.credit_card = CreditCard.create(build(:chargeable))
        user.save!
        expect(User::Risk).to_not receive(:contact_iffy_risk_analysis)
        @subscription.charge!
        expect(Purchase.count).to eq 2
        expect(Purchase.first.purchase_state).to eq "successful"
        expect(Purchase.last.purchase_state).to eq "successful"
        expect(@subscription.failed_at).to be(nil)
      end
    end

    describe "physical subscription" do
      before do
        @physical_link = create(:physical_product, user: create(:user), is_recurring_billing: true, price_cents: 2500, subscription_duration: :monthly)
        @physical_link.shipping_destinations << ShippingDestination.new(country_code: "US", one_item_rate_cents: 1000, multiple_items_rate_cents: 500)
        @physical_link.save!
        @subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @physical_link)
        @purchase = create(:purchase, link: @physical_link, displayed_price_cents: @physical_link.price_cents, is_original_subscription_purchase: true,
                                      subscription: @subscription, street_address: "1640 17th St", city: "San Francisco", state: "CA",
                                      zip_code: "94107", country: "United States", full_name: "Anish Gumroad", shipping_cents: 1000,
                                      created_at: 1.week.ago)
      end

      it "charges the price of the subscription and shipping" do
        expect { @subscription.charge! }.to change { Purchase.count }.by(1)
        purchase = Purchase.last
        expect(purchase.purchase_state).to eq "successful"
        expect(purchase.subscription).to eq @subscription
        expect(purchase.link).to eq @physical_link
        expect(purchase.shipping_cents).to eq 1000
        expect(purchase.total_transaction_cents).to eq 3500
        expect(purchase.is_original_subscription_purchase).to be(false)
      end

      it "copies shipping information over to new purchase" do
        expect { @subscription.charge! }.to change { Purchase.count }.by(1)
        purchase = Purchase.last
        expect(purchase.purchase_state).to eq "successful"
        expect(purchase.subscription).to eq @subscription
        expect(purchase.link).to eq @physical_link
        expect(purchase.street_address).to eq "1640 17th St"
        expect(purchase.city).to eq "San Francisco"
        expect(purchase.state).to eq "CA"
        expect(purchase.zip_code).to eq "94107"
        expect(purchase.country).to eq "United States"
        expect(purchase.full_name).to eq "Anish Gumroad"
      end

      describe "limited quantites" do
        before do
          @physical_link.update(max_purchase_count: 5)
        end

        it "does not reduce the number available" do
          expect { @subscription.charge! }.to_not change { @physical_link.reload.remaining_for_sale_count }
        end

        describe "multi quantity purchase" do
          before do
            @double_subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @physical_link)
            @double_purchase = create(:purchase, link: @physical_link, displayed_price_cents: @physical_link.price_cents, is_original_subscription_purchase: true,
                                                 subscription: @double_subscription, street_address: "1640 17th St", city: "San Francisco", state: "CA",
                                                 zip_code: "94107", country: "United States", full_name: "Anish Gumroad", quantity: 2, shipping_cents: 1500,
                                                 created_at: 1.week.ago)
          end

          it "charges the correct amounts" do
            expect { @double_subscription.charge! }.to change { Purchase.count }.by(1)
            purchase = Purchase.last
            expect(purchase.purchase_state).to eq "successful"
            expect(purchase.subscription).to eq @double_subscription
            expect(purchase.link).to eq @physical_link
            expect(purchase.shipping_cents).to eq 1500
            expect(purchase.total_transaction_cents).to eq 4000
            expect(purchase.quantity).to eq 2
            expect(purchase.is_original_subscription_purchase).to be(false)
          end

          it "does not reduce the number available" do
            expect { @double_subscription.charge! }.to_not change { @physical_link.reload.remaining_for_sale_count }
          end
        end
      end
    end

    describe "limited quantities" do
      describe "limited quantity" do
        before do
          @product = create(:subscription_product, user: create(:user), max_purchase_count: 10)
          @subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @product)
          @purchase = create(:purchase, link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: true,
                                        subscription: @subscription, created_at: 1.day.ago)
        end

        it "does not reduce the number available", :vcr do
          expect { @subscription.charge! }.to_not change { @product.reload.remaining_for_sale_count }
        end
      end

      describe "changing variants" do
        before do
          @product = create(:subscription_product, user: create(:user))
          @variant_category = create(:variant_category, link: @product, title: "colors")
          @variant = create(:variant, variant_category: @variant_category, name: "orange")
          @subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @product)
          @purchase = create(:purchase, link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: true,
                                        subscription: @subscription, variant_attributes: [@variant], created_at: 1.day.ago)
        end

        it "allows the recurring charge to go through regardless of variant changes", :vcr do
          new_variant_category = create(:variant_category, link: @product, title: "sizes")
          create(:variant, variant_category: new_variant_category, name: "large")
          @subscription.charge!
          expect(Purchase.last.purchase_state).to eq "successful"
        end
      end

      describe "limited variant quantity" do
        before do
          @product = create(:subscription_product, user: create(:user))
          @variant_category = create(:variant_category, link: @product, title: "colors")
          @variant = create(:variant, variant_category: @variant_category, name: "orange", max_purchase_count: 10)
          @subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @product)
          @purchase = create(:purchase_with_balance, link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: true,
                                                     subscription: @subscription, variant_attributes: [@variant], created_at: 1.day.ago)
        end

        it "creates a new purchase row", :vcr do
          expect { @subscription.charge! }.to change { Purchase.count }.by(1)
        end

        it "does not reduce the amount available", :vcr do
          expect { @subscription.charge! }.to_not change { @variant.reload.quantity_left }
        end

        describe "no variants left" do
          before do
            @product = create(:membership_product, user: create(:user))
            @subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @product)
            @variant_category = @product.tier_category
            @variant = create(:variant, variant_category: @variant_category, name: "2nd Tier", max_purchase_count: 1)
            @purchase = create(:purchase_with_balance, link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: true,
                                                       subscription: @subscription, variant_attributes: [@variant], created_at: 1.day.ago)
          end

          describe "new purchase" do
            it "does not allow extra purchases to go through" do
              @purchase = create(:purchase, link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: true,
                                            subscription: @subscription, variant_attributes: [@variant], created_at: Time.current)
              expect(@purchase.errors[:base]).to be_present
              expect(@purchase.error_code).to eq PurchaseErrorCode::VARIANT_SOLD_OUT
            end
          end

          it "allows recurring charges to go through and create new purchase row", :vcr do
            expect { @subscription.charge! }.to change {
              Purchase.count
            }.by(1)
          end

          it "makes the new purchase row successful", :vcr do
            @subscription.charge!
            expect(Purchase.last.purchase_state).to eq "successful"
          end
        end
      end

      describe "variable priced products" do
        before do
          @product = create(:subscription_product, user: create(:user), customizable_price: true)
          @subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @product)
          @purchase = create(:purchase, link: @product, email: @subscription.user.email, price_cents: 800,
                                        is_original_subscription_purchase: true, subscription: @subscription, created_at: 1.day.ago)
        end

        it "sets the price of the purchase row correctly", :vcr do
          purchase = @subscription.charge!
          expect(purchase.subscription).to eq @subscription
          expect(purchase.link).to eq @product
          expect(purchase.email).to eq @purchase.email
          expect(purchase.ip_address).to eq @purchase.ip_address
          expect(purchase.browser_guid).to eq @purchase.browser_guid
          expect(purchase.is_original_subscription_purchase).to be(false)
          expect(purchase.displayed_price_cents).to eq 800
          expect(purchase.price_cents).to eq 800
        end
      end

      describe "limited offer code quantity" do
        describe "offer codes still available" do
          before do
            @product = create(:subscription_product, user: create(:user))
            @offer_code = create(:offer_code, products: [@product], code: "thanks9", max_purchase_count: 2)
            @subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @product)
            @purchase = create(:purchase, link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: true,
                                          subscription: @subscription, offer_code: @offer_code, discount_code: @offer_code.code, created_at: 1.day.ago)
          end

          it "creates a new purchase row", :vcr do
            expect { @subscription.charge! }.to change { Purchase.count }.by(1)
          end

          it "does not reduce the amount available", :vcr do
            expect { @subscription.charge! }.to_not change { @offer_code.reload.is_valid_for_purchase? }
          end
        end

        describe "last offer code available" do
          before do
            @product = create(:membership_product, user: create(:user))
            @variant = @product.tiers.first
            @subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @product)
            @offer_code = create(:offer_code, products: [@product], max_purchase_count: 1, code: "thanks1")
            @purchase = create(:purchase, link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: true, subscription: @subscription,
                                          offer_code: @offer_code, discount_code: @offer_code.code, variant_attributes: [@variant], created_at: 1.day.ago)
          end

          it "does not allow extra purchases to go through" do
            p = create(:purchase, link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: true, subscription: @subscription,
                                  offer_code: @offer_code, discount_code: @offer_code.code, variant_attributes: [@variant], created_at: Time.current)
            expect(p.error_code).to eq "offer_code_sold_out"
          end

          it "allows recurring charges to go through and create new purchase row", :vcr do
            expect { @subscription.charge! }.to change { Purchase.count }.by(1)
          end

          it "makes the new purchase row successful", :vcr do
            @subscription.charge!
            expect(Purchase.last.purchase_state).to eq "successful"
          end
        end
      end
    end

    describe "discount with duration" do
      let(:user) { create(:user) }
      let(:product) { create(:membership_product_with_preset_tiered_pricing, user:) }
      let(:offer_code) { create(:offer_code, products: [product]) }
      let(:subscription) { create(:membership_purchase, link: product, offer_code:, variant_attributes: [product.alive_variants.first], price_cents: 200).subscription }

      before do
        subscription.original_purchase.create_purchase_offer_code_discount!(offer_code:, offer_code_amount: 100, offer_code_is_percent: false, pre_discount_minimum_price_cents: 300, duration_in_billing_cycles: 1)
      end

      context "when the discount is no longer valid" do
        it "charges the full price" do
          subscription.charge!

          purchase = Purchase.last
          expect(purchase.offer_code).to eq(nil)
          expect(purchase.displayed_price_cents).to eq(300)
          expect(purchase.price_cents).to eq(300)
          expect(purchase.purchase_offer_code_discount).to eq(nil)
        end
      end

      context "when the discount is still valid" do
        before do
          subscription.original_purchase.purchase_offer_code_discount.update!(duration_in_billing_cycles: 2)
        end

        it "charges the discounted price" do
          subscription.charge!

          purchase = Purchase.last
          expect(purchase.displayed_price_cents).to eq(200)
          expect(purchase.price_cents).to eq(200)
          purchase_offer_code_discount = purchase.purchase_offer_code_discount
          expect(purchase_offer_code_discount.offer_code).to eq(offer_code)
          expect(purchase_offer_code_discount.offer_code_amount).to eq(100)
          expect(purchase_offer_code_discount.offer_code_is_percent).to eq(false)
        end
      end
    end

    describe "yen" do
      # need to do the currency conversion
      before do
        @product = create(:subscription_product, user: create(:user), price_currency_type: "jpy", price_cents: 400)
        @subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @product)
        @purchase = create(:purchase, link: @product, email: @subscription.user.email, price_cents: get_usd_cents("jpy", @product.price_cents),
                                      displayed_price_cents: @product.price_cents, is_original_subscription_purchase: true, subscription: @subscription)
      end

      # to handle case where they buy subscription for 400 yen and then exchange rate changes,
      # they should only be charged 400 yen
      it "charges user at the same amount that they originally subscribed in", :vcr do
        # change the currency

        allow_any_instance_of(Purchase).to receive(:get_rate).with(:jpy).and_return(90)
        travel_to(1.month.from_now) do
          purchase = @subscription.charge!
          expect(purchase.subscription).to eq @subscription
          expect(purchase.link).to eq @product
          expect(purchase.email).to eq @purchase.email
          expect(purchase.ip_address).to eq @purchase.ip_address
          expect(purchase.browser_guid).to eq @purchase.browser_guid
          expect(purchase.is_original_subscription_purchase).to be(false)
          expect(purchase.displayed_price_cents).to eq @purchase.displayed_price_cents
          expect(purchase.price_cents).to_not eq @purchase.price_cents
        end
      end
    end

    describe "price changes" do
      before do
        @product = create(:subscription_product, user: create(:user), price_cents: 400)
        @subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @product)
        @purchase = create(:purchase, link: @product, email: @subscription.user.email, price_cents: @product.price_cents,
                                      is_original_subscription_purchase: true, subscription: @subscription, created_at: Date.yesterday)
      end

      it "charges the user the original amount", :vcr do
        @product.update(price_cents: 500)

        purchase = @subscription.charge!
        expect(purchase.subscription).to eq @subscription
        expect(purchase.link).to eq @product
        expect(purchase.email).to eq @purchase.email
        expect(purchase.ip_address).to eq @purchase.ip_address
        expect(purchase.browser_guid).to eq @purchase.browser_guid
        expect(purchase.is_original_subscription_purchase).to be(false)
        expect(purchase.displayed_price_cents).to eq @purchase.displayed_price_cents
        expect(purchase.price_cents).to eq @purchase.price_cents
        expect(purchase.purchase_state).to eq "successful"
      end

      describe "with foreign currency" do
        before do
          @product = create(:subscription_product, user: create(:user), price_currency_type: "jpy", price_cents: 400)
          @subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @product)
          @purchase = create(:purchase, link: @product, email: @subscription.user.email, price_cents: get_usd_cents("jpy", @product.price_cents),
                                        displayed_price_cents: @product.price_cents, is_original_subscription_purchase: true,
                                        subscription: @subscription, created_at: Date.yesterday)
        end

        it "charges the user the original amount in the foreign currency", :vcr do
          @product.update(price_cents: 500)
          allow_any_instance_of(Purchase).to receive(:get_rate).with(:jpy).and_return(50)

          purchase = @subscription.charge!
          expect(purchase.subscription).to eq @subscription
          expect(purchase.link).to eq @product
          expect(purchase.email).to eq @purchase.email
          expect(purchase.ip_address).to eq @purchase.ip_address
          expect(purchase.browser_guid).to eq @purchase.browser_guid
          expect(purchase.is_original_subscription_purchase).to be(false)
          expect(purchase.displayed_price_cents).to eq @purchase.displayed_price_cents
          expect(purchase.price_cents).to eq 800 # 400 yens in usd cents based on the new rate
          expect(purchase.purchase_state).to eq "successful"
        end
      end
    end

    describe "failure" do
      describe "stripe unavailable" do
        before do
          allow(Stripe::PaymentIntent).to receive(:create).and_raise(Stripe::APIConnectionError)
        end

        it "does not send out email", :vcr do
          expect(CustomerLowPriorityMailer).to_not receive(:subscription_card_declined)
          @subscription.charge!
        end

        it "does not schedule ChargeDeclinedReminderWorker", :vcr do
          @subscription.charge!

          expect(ChargeDeclinedReminderWorker).not_to have_enqueued_sidekiq_job(@subscription.id)
        end

        it "requeues RecurringCharge", :vcr do
          @subscription.charge!

          expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(@subscription.id)
        end

        it "schedules the UnsubscribeAndFail job" do
          @subscription.charge!
          expect(UnsubscribeAndFailWorker).to have_enqueued_sidekiq_job(@subscription.id)
        end
      end

      describe "from card declined email" do
        it "does not send out email", :vcr do
          expect(CustomerLowPriorityMailer).to_not receive(:subscription_card_declined)
          @subscription.charge!(from_failed_charge_email: true)
        end

        it "does not schedule ChargeDeclinedReminderWorker", :freeze_time, :vcr do
          @subscription.charge!(from_failed_charge_email: true)

          expect(ChargeDeclinedReminderWorker).not_to have_enqueued_sidekiq_job(@subscription.id)
        end

        it "schedules the UnsubscribeAndFail job", :freeze_time, :vcr do
          allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!).and_raise(ChargeProcessorCardError.new("card_declined"))
          @subscription.charge!(from_failed_charge_email: true)

          expect(UnsubscribeAndFailWorker).to have_enqueued_sidekiq_job(@subscription.id)
        end

        it "does not requeue 1 hour job", :freeze_time, :vcr do
          allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!).and_raise(ChargeProcessorUnavailableError.new)
          @subscription.charge!(from_failed_charge_email: true)

          expect(RecurringChargeWorker).to_not have_enqueued_sidekiq_job(@subscription.id)
        end
      end

      describe "user removed credit card" do
        before do
          @subscription.user.update!(credit_card_id: nil)
        end

        it "sends charge declined emails" do
          mail_double = double
          allow(mail_double).to receive(:deliver_later)
          expect(CustomerLowPriorityMailer).to receive(:subscription_card_declined).and_return(mail_double)
          @subscription.charge!
        end

        it "schedules the UnsubscribeAndFail job" do
          @subscription.charge!
          expect(UnsubscribeAndFailWorker).to have_enqueued_sidekiq_job(@subscription.id)
        end
      end

      context "when there are no successful, non-refunded or reversed purchases" do
        it "schedules the UnsubscribeAndFail job" do
          @subscription.original_purchase.update!(chargeback_date: 1.day.ago)
          allow(Stripe::PaymentIntent).to receive(:create).and_raise(Stripe::APIConnectionError)

          @subscription.charge!
          expect(UnsubscribeAndFailWorker).to have_enqueued_sidekiq_job(@subscription.id)
        end
      end
    end

    describe "double charged" do
      before do
        create(:purchase, link: @product, ip_address: @purchase.ip_address, email: @purchase.email, created_at: Time.current)
      end

      it "does not create the purchase row", :vcr do
        expect do
          @subscription.charge!
        end.to raise_error(StateMachines::InvalidTransition)
      end
    end

    describe "card error" do
      describe "card_declined" do
        before do
          allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!).and_raise(ChargeProcessorCardError.new("card_declined"))
        end

        it "sends the correct email", :vcr do
          mail_double = double
          allow(mail_double).to receive(:deliver_later)
          expect(CustomerLowPriorityMailer).to receive(:subscription_card_declined).and_return(mail_double)
          @subscription.charge!
        end

        it "schedules ChargeDeclinedReminderWorker", :freeze_time, :vcr do
          @subscription.charge!

          expect(ChargeDeclinedReminderWorker).to have_enqueued_sidekiq_job(@subscription.id).in(3.days)
        end

        it "schedules the UnsubscribeAndFail job" do
          @subscription.charge!
          expect(UnsubscribeAndFailWorker).to have_enqueued_sidekiq_job(@subscription.id)
        end

        describe "invalid_cvc" do
          before do
            allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!).and_raise(ChargeProcessorCardError.new("invalid_cvc"))
          end

          it "sends the correct email", :vcr do
            mail_double = double
            allow(mail_double).to receive(:deliver_later)
            expect(CustomerLowPriorityMailer).to receive(:subscription_card_declined).and_return(mail_double)
            @subscription.charge!
          end

          it "schedules ChargeDeclinedReminderWorker", :freeze_time, :vcr do
            @subscription.charge!

            expect(ChargeDeclinedReminderWorker).to have_enqueued_sidekiq_job(@subscription.id)
          end

          it "requeues UnsubscribeAndFail", :freeze_time, :vcr do
            @subscription.charge!

            expect(UnsubscribeAndFailWorker).to have_enqueued_sidekiq_job(@subscription.id)
          end
        end
      end

      describe "card_declined_insufficient_funds" do
        before do
          allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!).and_raise(ChargeProcessorCardError.new("card_declined_insufficient_funds"))
        end

        it "emails the subscriber" do
          mail_double = double
          allow(mail_double).to receive(:deliver_later)
          expect(CustomerLowPriorityMailer).to receive(:subscription_card_declined).and_return(mail_double)
          @subscription.charge!
        end

        it "schedules a ChargeDeclinedReminderWorker" do
          @subscription.charge!

          expect(ChargeDeclinedReminderWorker).to have_enqueued_sidekiq_job(@subscription.id)
        end

        it "requeues RecurringCharge", :freeze_time do
          @subscription.charge!
          expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(@subscription.id).in(1.day)
        end

        it "schedules the UnsubscribeAndFail job" do
          @subscription.charge!
          expect(UnsubscribeAndFailWorker).to have_enqueued_sidekiq_job(@subscription.id)
        end
      end
    end

    describe "affiliates" do
      it "associates the recurring charges to the same affiliate", :vcr do
        @product.update!(price_cents: 10_00)
        affiliate_user = create(:affiliate_user)
        direct_affiliate = create(:direct_affiliate, affiliate_user:, seller: @product.user, affiliate_basis_points: 1000, products: [@product])
        subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @product)
        purchase = create(:purchase_in_progress, link: @product, email: subscription.user.email, full_name: "squiddy",
                                                 price_cents: @product.price_cents, is_original_subscription_purchase: true,
                                                 subscription:, created_at: 2.days.ago, affiliate: direct_affiliate)
        purchase.process!
        purchase.update_balance_and_mark_successful!
        recurring_purchase = subscription.charge!
        expect(recurring_purchase.purchase_state).to eq "successful"
        expect(recurring_purchase.affiliate_credit_cents).to eq(79)
        expect(recurring_purchase.affiliate).to eq(direct_affiliate)
        expect(recurring_purchase.affiliate_credit.affiliate).to eq(direct_affiliate)
        expect(@product.user.unpaid_balance_cents).to eq(712 * 2) # original subs purchase and the recurring purchase.
        expect(affiliate_user.unpaid_balance_cents).to eq(79 * 2)
      end

      it "does not associate the recurring charge to the affiliate if affiliate is using a Brazilian Stripe Connect account", :vcr do
        @product.update!(price_cents: 10_00)
        affiliate_user = create(:affiliate_user)
        direct_affiliate = create(:direct_affiliate, affiliate_user:, seller: @product.user, affiliate_basis_points: 1000, products: [@product])
        subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @product)
        purchase = create(:purchase_in_progress, link: @product, email: subscription.user.email, full_name: "squiddy",
                                                 price_cents: @product.price_cents, is_original_subscription_purchase: true,
                                                 subscription:, created_at: 2.days.ago, affiliate: direct_affiliate)
        purchase.process!
        purchase.update_balance_and_mark_successful!
        expect(purchase.affiliate_credit_cents).to eq(79)
        expect(purchase.affiliate).to eq(direct_affiliate)
        expect(purchase.affiliate_credit.affiliate).to eq(direct_affiliate)
        expect(@product.user.reload.unpaid_balance_cents).to eq(712) # original subscription purchase
        expect(affiliate_user.reload.unpaid_balance_cents).to eq(79)

        brazilian_stripe_account = create(:merchant_account_stripe_connect, user: affiliate_user, country: "BR")
        affiliate_user.update!(check_merchant_account_is_linked: true)
        expect(affiliate_user.merchant_account(StripeChargeProcessor.charge_processor_id)).to eq brazilian_stripe_account

        recurring_purchase = subscription.charge!
        expect(recurring_purchase.purchase_state).to eq "successful"
        expect(recurring_purchase.affiliate_credit_cents).to eq(0)
        expect(recurring_purchase.affiliate).to be nil
        expect(recurring_purchase.affiliate_credit).to be nil
        expect(@product.user.reload.unpaid_balance_cents).to eq(712 + 791) # original subscription purchase and the recurring purchase.
        expect(affiliate_user.reload.unpaid_balance_cents).to eq(79)
      end
    end

    describe "recommended" do
      before do
        allow_any_instance_of(Link).to receive(:recommendable?).and_return(true)
      end

      it "shows the recurring charges as recommended, charge the extra fee, and create a new recommended_purchase_info", :vcr do
        @product.update!(price_cents: 10_00)
        subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @product)
        purchase = create(:purchase_in_progress, link: @product, email: subscription.user.email, full_name: "squiddy",
                                                 price_cents: @product.price_cents, is_original_subscription_purchase: true,
                                                 subscription:, created_at: 2.days.ago, was_product_recommended: true)
        purchase.process!
        purchase.update_balance_and_mark_successful!
        recurring_purchase = subscription.charge!
        expect(recurring_purchase.purchase_state).to eq "successful"
        expect(recurring_purchase.fee_cents).to eq(209) # 100c (10% flat fee) + 50c + 29c (2.9% cc fee) + 30c (fixed cc fee)
        expect(recurring_purchase.was_product_recommended).to eq(true)
        expect(recurring_purchase.recommended_purchase_info).to be_present
        expect(recurring_purchase.recommended_purchase_info.is_recurring_purchase).to eq(true)
        expect(recurring_purchase.recommended_purchase_info.discover_fee_per_thousand).to eq(100)
        expect(@product.user.unpaid_balance_cents).to eq(791 + 700) # original subs purchase and the recurring purchase.
      end

      context "discover fee" do
        it "charges the discover fee percentage from the original purchase instead of the current product discover fee" do
          setup_subscription(was_product_recommended: true, discover_fee_per_thousand: 300)
          @product.update!(discover_fee_per_thousand: 400)
          allow_any_instance_of(Subscription).to receive(:mor_fee_applicable?).and_return(false)

          travel_to(1.day.from_now) { @subscription.charge! }

          recurring_purchase = @subscription.purchases.last
          expect(recurring_purchase.discover_fee_per_thousand).to eq(300)
          expect(recurring_purchase.fee_cents).to eq(264) # 599*0.09 + 599*0.3 + 30c
        end
      end

      context "free trials" do
        it "charges the discover fee percentage from the original free trial purchase instead of the current product discover fee" do
          setup_subscription(free_trial: true, was_product_recommended: true, discover_fee_per_thousand: 300)
          @product.update!(discover_fee_per_thousand: 100)
          allow_any_instance_of(Subscription).to receive(:mor_fee_applicable?).and_return(false)

          travel_to(1.day.from_now) { @subscription.charge! }

          recurring_purchase = @subscription.purchases.last
          expect(recurring_purchase.discover_fee_per_thousand).to eq(300)
          expect(recurring_purchase.fee_cents).to eq(264) # 599*0.09 + 599*0.3 + 30c
        end
      end
    end

    describe "free trial ratings" do
      it "allows free trial subscriptions' ratings to be counted on successful charge" do
        purchase = create(:free_trial_membership_purchase)
        expect(purchase.should_exclude_product_review?).to eq true

        purchase.subscription.charge!

        expect(purchase.reload.should_exclude_product_review?).to eq false
      end
    end
  end

  describe "#schedule_charge", :freeze_time do
    before do
      @scheduled_time = Time.current + 1.day
    end

    it "schedules RecurringCharge at the specified time" do
      @subscription.schedule_charge(@scheduled_time)

      expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(@subscription.id).at(@scheduled_time)
    end

    it "logs the scheduling operation" do
      log_text = "Scheduled RecurringChargeWorker(#{@subscription.id}) to run at #{@scheduled_time}"
      expect(Rails.logger).to receive(:info).with(log_text).and_call_original

      @subscription.schedule_charge(@scheduled_time)
    end
  end

  describe "#unsubscribe_and_fail!" do
    it "unsubscribes the user" do
      expect(@subscription.failed_at.nil?).to eq(true)
      expect(@subscription.deactivated_at.nil?).to eq(true)
      @subscription.unsubscribe_and_fail!
      expect(@subscription.failed_at.nil?).to eq(false)
      expect(@subscription.deactivated_at.nil?).to eq(false)
    end

    it "does not set cancelled_by_buyer" do
      expect(@subscription.cancelled_by_buyer).to be(false)
      @subscription.unsubscribe_and_fail!
      expect(@subscription.cancelled_by_buyer).to be(false)
    end

    context "when creator has payment notifications ON" do
      it "emails the creator" do
        expect(@subscription.seller.enable_payment_email).to be_truthy
        expect do
          @subscription.unsubscribe_and_fail!
        end.to have_enqueued_mail(ContactingCreatorMailer, :subscription_autocancelled).with(@subscription.id)
      end
    end

    context "when creator has payment notifications OFF" do
      it "does not email the creator" do
        @subscription.seller.update!(enable_payment_email: false)
        expect do
          @subscription.unsubscribe_and_fail!
        end.not_to have_enqueued_mail(ContactingCreatorMailer, :subscription_autocancelled).with(@subscription.id)
      end
    end

    it "emails the customer" do
      expect do
        @subscription.unsubscribe_and_fail!
      end.to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_autocancelled).with(@subscription.id)
    end

    it "enqueues the ping job to notify seller of subscription cancellation" do
      @subscription.unsubscribe_and_fail!

      expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(nil, nil, ResourceSubscription::CANCELLED_RESOURCE_NAME, @subscription.id)
    end

    it "enqueues the ping job to notify seller of subscription ending" do
      @subscription.unsubscribe_and_fail!

      expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(nil, nil, ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME, @subscription.id)
    end
  end

  describe "#end_subscription!" do
    it "ends the subscription" do
      @subscription.end_subscription!
      expect(@subscription.ended_at.nil?).to eq(false)
      expect(@subscription.deactivated_at.nil?).to eq(false)
    end

    it "emails the customer" do
      expect do
        @subscription.end_subscription!
      end.to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_ended).with(@subscription.id)
    end

    context "when creator has payment notifications ON" do
      it "emails the creator" do
        expect(@subscription.seller.enable_payment_email).to be_truthy
        expect do
          @subscription.end_subscription!
        end.to have_enqueued_mail(ContactingCreatorMailer, :subscription_ended).with(@subscription.id)
      end
    end

    context "when creator has payment notifications OFF" do
      it "does not email the creator" do
        @subscription.seller.update!(enable_payment_email: false)
        expect do
          @subscription.end_subscription!
        end.not_to have_enqueued_mail(ContactingCreatorMailer, :subscription_ended).with(@subscription.id)
      end
    end

    it "enqueues the ping job to notify seller of subscription ending" do
      @subscription.end_subscription!

      expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(nil, nil, ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME, @subscription.id)
    end
  end

  describe "#cancel!" do
    describe "by_seller=false" do
      it "sets cancelled_at and user_requested_cancellation", :freeze_time do
        expect { @subscription.cancel!(by_seller: false) }
          .to change { @subscription.reload.user_requested_cancellation_at.try(:utc).try(:to_i) }.from(nil).to(Time.current.to_i)
      end

      it "sets cancelled_by_buyer correctly" do
        expect(@subscription.cancelled_by_buyer).to be(false)
        @subscription.cancel!(by_seller: false)
        expect(@subscription.cancelled_by_buyer).to be(true)
      end

      it "emails the buyer" do
        expect do
          @subscription.cancel!(by_seller: false)
        end.to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_cancelled).with(@subscription.id)
      end

      context "when creator has payment notifications ON" do
        it "emails the creator" do
          expect(@subscription.seller.enable_payment_email).to be_truthy
          expect do
            @subscription.cancel!(by_seller: false)
          end.to have_enqueued_mail(ContactingCreatorMailer, :subscription_cancelled_by_customer).with(@subscription.id)
        end
      end

      context "when creator has payment notifications OFF" do
        it "does not email the creator" do
          @subscription.seller.update!(enable_payment_email: false)
          expect do
            @subscription.cancel!(by_seller: false)
          end.not_to have_enqueued_mail(ContactingCreatorMailer, :subscription_cancelled_by_customer).with(@subscription.id)
        end
      end

      it "enqueues the ping job to notify seller of subscription cancellation" do
        @subscription.cancel!(by_seller: false)

        expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(nil, nil, ResourceSubscription::CANCELLED_RESOURCE_NAME, @subscription.id)
      end
    end

    describe "by_seller=true" do
      it "sets cancelled_at and user_requested_cancellation", :freeze_time do
        expect { @subscription.cancel!(by_seller: true) }
          .to change { @subscription.reload.user_requested_cancellation_at.try(:utc).try(:to_i) }.from(nil).to(Time.current.to_i)
      end

      it "sets cancelled_by_buyer correctly" do
        expect(@subscription.cancelled_by_buyer).to be(false)
        @subscription.cancel!(by_seller: true)
        expect(@subscription.cancelled_by_buyer).to be(false)
      end

      it "emails the buyer" do
        expect do
          @subscription.cancel!(by_seller: true)
        end.to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_cancelled_by_seller).with(@subscription.id)
      end

      context "when creator has payment notifications ON" do
        it "emails the creator" do
          expect(@subscription.seller.enable_payment_email).to be_truthy
          expect do
            @subscription.cancel!(by_seller: true)
          end.to have_enqueued_mail(ContactingCreatorMailer, :subscription_cancelled).with(@subscription.id)
        end
      end

      context "when creator has payment notifications OFF" do
        it "does not email the creator" do
          @subscription.seller.update!(enable_payment_email: false)
          expect do
            @subscription.cancel!(by_seller: true)
          end.not_to have_enqueued_mail(ContactingCreatorMailer, :subscription_cancelled).with(@subscription.id)
        end
      end

      it "enqueues the ping job to notify seller of subscription cancellation" do
        @subscription.cancel!(by_seller: true)

        expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(nil, nil, ResourceSubscription::CANCELLED_RESOURCE_NAME, @subscription.id)
      end
    end

    describe "by_admin=true" do
      it "sets the cancelled_by_admin correctly" do
        expect(@subscription.cancelled_by_admin).to be(false)
        @subscription.cancel!(by_admin: true)
        expect(@subscription.cancelled_by_admin).to be(true)
      end

      it "emails the buyer" do
        mail_double = double
        allow(mail_double).to receive(:deliver_later)
        expect(CustomerLowPriorityMailer).to receive(:subscription_cancelled_by_seller).with(@subscription.id).and_return(mail_double)
        @subscription.cancel!(by_admin: true)
      end

      context "when creator has payment notifications ON" do
        it "emails the creator" do
          expect(@subscription.seller.enable_payment_email).to be_truthy
          expect do
            @subscription.cancel!(by_admin: true)
          end.to have_enqueued_mail(ContactingCreatorMailer, :subscription_cancelled).with(@subscription.id)
        end
      end

      context "when creator has payment notifications OFF" do
        it "does not email the creator" do
          @subscription.seller.update!(enable_payment_email: false)
          expect do
            @subscription.cancel!(by_admin: true)
          end.not_to have_enqueued_mail(ContactingCreatorMailer, :subscription_cancelled).with(@subscription.id)
        end
      end
    end

    describe "installment plans" do
      let(:installment_plan_purchase) { create(:installment_plan_purchase) }
      let(:subscription) { installment_plan_purchase.subscription }

      it "cannot be cancelled by the buyer" do
        expect { subscription.cancel!(by_seller: false) }
          .to raise_error(ActiveRecord::RecordInvalid, "Validation failed: Installment plans cannot be cancelled by the customer")
      end

      it "can be cancelled by the seller" do
        expect { subscription.cancel!(by_seller: true) }
          .to change { subscription.reload.cancelled_at }.from(nil)
      end
    end
  end

  describe "#deactivate!" do
    before do
      @creator = create(:user)
      @product = create(:subscription_product, user: @creator)
      @subscription = create(:subscription, link: @product, cancelled_at: 2.days.ago)
      @sale = create(:purchase, is_original_subscription_purchase: true, link: @product, subscription: @subscription, email: "test@gmail.com", created_at: 1.week.ago, price_cents: 100)
    end

    it "sets deactivated_at" do
      @subscription.deactivate!
      expect(@subscription.reload.deactivated_at).to be_present
    end

    it "enqueues deactivate integrations worker" do
      @subscription.deactivate!
      expect(DeactivateIntegrationsWorker).to have_enqueued_sidekiq_job(@subscription.original_purchase.id)
    end

    it "creates a subscription_event of type deactivated" do
      @subscription.deactivate!
      expect(@subscription.subscription_events.last.event_type).to eq("deactivated")
    end

    describe "when creator has member cancellation workflow jobs" do
      context "and the membership has been cancelled" do
        it "schedules a member cancellation installment for a creator's seller workflow" do
          workflow = create(:seller_workflow, seller: @creator, workflow_trigger: "member_cancellation")
          installment = create(:published_installment, workflow:, workflow_trigger: "member_cancellation")
          installment_rule = create(:installment_rule, installment:, delayed_delivery_time: 1.day)

          @subscription.deactivate!
          @subscription.reload

          expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(installment.id, installment_rule.version, nil, nil, nil, @subscription.id).at(@subscription.deactivated_at + installment_rule.delayed_delivery_time)
        end

        it "schedules a member cancellation installment for a creator's product workflow" do
          workflow = create(:workflow, seller: @creator, link: @product, workflow_trigger: "member_cancellation")
          installment = create(:published_installment, link: @product, workflow:, workflow_trigger: "member_cancellation")
          installment_rule = create(:installment_rule, installment:, delayed_delivery_time: 1.day)

          @subscription.deactivate!
          @subscription.reload

          expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(installment.id, installment_rule.version, nil, nil, nil, @subscription.id).at(@subscription.deactivated_at + installment_rule.delayed_delivery_time)
        end

        it "does not schedule a member cancellation installment for workflows that are not product or seller workflows, even if their trigger is member cancellation" do
          workflow = create(:audience_workflow, seller: @creator, workflow_trigger: "member_cancellation")
          installment = create(:published_installment, workflow:, workflow_trigger: "member_cancellation")
          create(:installment_rule, installment:, delayed_delivery_time: 1.day)

          @subscription.deactivate!

          expect(SendWorkflowInstallmentWorker.jobs.size).to eq(0)
        end

        it "does not schedule a member cancellation installment if the seller workflow isn't for member cancellation" do
          workflow = create(:seller_workflow, seller: @creator, workflow_trigger: nil)
          installment = create(:published_installment, workflow:, workflow_trigger: "member_cancellation")
          create(:installment_rule, installment:, delayed_delivery_time: 1.day)

          @subscription.deactivate!

          expect(SendWorkflowInstallmentWorker.jobs.size).to eq(0)
        end

        it "does not schedule a member cancellation installment if the product workflow isn't for member cancellation" do
          workflow = create(:workflow, seller: @creator, link: @product, workflow_trigger: nil)
          installment = create(:published_installment, link: @product, workflow:, workflow_trigger: "member_cancellation")
          create(:installment_rule, installment:, delayed_delivery_time: 1.day)

          @subscription.deactivate!

          expect(SendWorkflowInstallmentWorker.jobs.size).to eq(0)
        end

        it "does not schedule a member cancellation installment if the workflow doesn't apply to the purchase" do
          workflow = create(:workflow, seller: @creator, link: @product, workflow_trigger: "member_cancellation", created_after: 3.days.ago)
          installment = create(:published_installment, link: @product, workflow:, workflow_trigger: "member_cancellation")
          create(:installment_rule, installment:, delayed_delivery_time: 1.day)

          @purchase.update!(created_at: 7.days.ago)

          @subscription.deactivate!

          expect(SendWorkflowInstallmentWorker.jobs.size).to eq(0)
        end

        it "does not schedule a member cancellation installment if the installment rule is nil" do
          workflow = create(:workflow, seller: @creator, link: @product, workflow_trigger: "member_cancellation")
          create(:published_installment, link: @product, workflow:, workflow_trigger: "member_cancellation")

          @subscription.deactivate!

          expect(SendWorkflowInstallmentWorker.jobs.size).to eq(0)
        end
      end

      context "and the membership has ended for other reasons" do
        let(:workflow) { create(:seller_workflow, seller: @creator, workflow_trigger: "member_cancellation") }
        let(:installment) { create(:published_installment, workflow:, workflow_trigger: "member_cancellation") }
        let!(:installment_rule) { create(:installment_rule, installment:, delayed_delivery_time: 1.day) }

        context "such as payment failures" do
          it "does not schedule member cancellation workflow jobs" do
            @subscription.update!(cancelled_at: nil, failed_at: 1.hour.ago)

            @subscription.deactivate!

            expect(SendWorkflowInstallmentWorker.jobs.size).to eq(0)
          end
        end

        context "such as reaching the end of its fixed-length duration" do
          it "does not schedule member cancellation workflow jobs" do
            @subscription.update!(cancelled_at: nil, ended_at: 1.hour.ago)

            @subscription.deactivate!

            expect(SendWorkflowInstallmentWorker.jobs.size).to eq(0)
          end
        end
      end
    end
  end

  describe "#update_current_plan!" do
    it "archives the existing original purchase" do
      setup_subscription

      @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price)

      expect(@original_purchase.reload.is_archived_original_subscription_purchase).to eq true
    end

    it "creates a new original purchase with the updated tier, price, and quantity" do
      setup_subscription

      new_purchase = @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price, new_quantity: 2)

      expect(@subscription.reload.original_purchase).to eq new_purchase
      new_purchase.reload
      expect(new_purchase).to be_persisted
      expect(new_purchase.displayed_price_cents).to eq 40_00
      expect(new_purchase.variant_attributes).to eq [@new_tier]
      expect(new_purchase.purchase_state).to eq "not_charged"
    end

    it "copies correct attributes from the original purchase" do
      setup_subscription(free_trial: true, was_product_recommended: true)
      allow_any_instance_of(Subscription).to receive(:mor_fee_applicable?).and_return(false)

      @original_purchase.update!(
        # copied
        full_name: "Jane Gumroad",
        street_address: "100 Main Street",
        city: "San Francisco",
        state: "CA",
        zip_code: "11111",
        country: "US",
        referrer: "https://gumroad.com",
        ip_country: "USA",
        ip_state: "CA",
        offer_code: create(:offer_code, products: [@product], amount_cents: 300),
        affiliate: create(:direct_affiliate, seller: @product.user, affiliate_basis_points: 200),
        was_product_recommended: true,
        # excluded
        stripe_transaction_id: "abc123",
        stripe_status: "foo",
        stripe_error_code: "bar",
        error_code: "baz",
        # calculated
        affiliate_credit_cents: 11, # $5.99 * 200/10,000
      )
      @original_purchase.seller.mark_compliant!(author_name: "Iffy")
      @original_purchase.purchase_custom_fields.create!(name: "favorite color", type: CustomField::TYPE_TEXT, value: "Blue")
      @original_purchase.create_recommended_purchase_info({
                                                            recommended_link_id: @original_purchase.link_id,
                                                            recommended_by_link_id: @original_purchase.link_id,
                                                            recommendation_type: RecommendationType::GUMROAD_DISCOVER_RECOMMENDATION,
                                                            is_recurring_purchase: true,
                                                            discover_fee_per_thousand: 300
                                                          })

      new_purchase = @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price, new_quantity: 2)

      # copied attributes
      [:seller_id, :email, :link_id, :displayed_price_currency_type, :full_name,
       :street_address, :country, :state, :zip_code, :city, :ip_address, :ip_state,
       :ip_country, :browser_guid, :referrer, :was_product_recommended,
       :offer_code_id, :affiliate_id, :credit_card_id, :is_free_trial_purchase,
       :custom_fields].each do |purchase_attr|
        expect(new_purchase.send(purchase_attr)).to eq @original_purchase.send(purchase_attr)
      end
      expect(new_purchase.purchase_custom_fields.pluck(:name, :value, :field_type)).to eq(@original_purchase.purchase_custom_fields.pluck(:name, :value, :field_type))

      # excluded attributes
      expect(new_purchase.stripe_transaction_id).to be_nil
      expect(new_purchase.succeeded_at).to be_nil
      expect(new_purchase.stripe_status).to be_nil
      expect(new_purchase.stripe_error_code).to be_nil
      expect(new_purchase.error_code).to be_nil

      # newly calculated attributes
      expect(new_purchase.quantity).to eq 2
      expect(new_purchase.price_cents).to eq 3400 # $40 - $6 offer code
      expect(new_purchase.displayed_price_cents).to eq 3400 # $40 - $6 offer code
      expect(new_purchase.fee_cents).to eq 1326 # 30% discover fee + 9% Gumroad fee
      expect(new_purchase.affiliate_credit_cents).to eq 41 # $34 * 200/10,000 - 2% of the $13.26 fee
      expect(new_purchase.total_transaction_cents).to eq 3400 # $40 - $6 offer code

      # copied associations
      [:recommended_link_id, :recommended_by_link_id, :recommendation_type,
       :is_recurring_purchase, :discover_fee_per_thousand].each do |rec_purchase_info_attr|
        expect(new_purchase.recommended_purchase_info.send(rec_purchase_info_attr)).to eq(@original_purchase.recommended_purchase_info.send(rec_purchase_info_attr))
      end
      expect(new_purchase.purchase_custom_fields.pluck(:name, :value, :field_type)).to eq @original_purchase.purchase_custom_fields.pluck(:name, :value, :field_type)
    end

    it "creates a purchase event for the new original purchase" do
      setup_subscription

      create(:purchase_event, purchase: @original_purchase)

      new_purchase = @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price)

      event = new_purchase.events.first
      expect(new_purchase.events.size).to eq 1
      expect(event.purchase_id).to eq new_purchase.id
      expect(event.price_cents).to eq new_purchase.price_cents
      expect(event.is_recurring_subscription_charge).to eq false
      expect(event.purchase_state).to eq "not_charged"
    end

    it "does not charge the user" do
      setup_subscription

      expect do
        @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price)
      end.not_to change { @subscription.reload.purchases.not_is_original_subscription_purchase.count }
    end

    it "does not update the creator's balance" do
      setup_subscription

      creator = @product.user
      expect(creator.balances.count).to eq 1
      expect do
        @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price)
      end.not_to change { creator.reload.balances.count }
    end

    context "updating to a PWYW tier" do
      before :each do
        setup_subscription
        @new_tier.update!(customizable_price: true)
      end

      it "calculates displayed_price_cents correctly" do
        new_purchase = @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price, perceived_price_cents: 20_01)

        expect(new_purchase.reload.displayed_price_cents).to eq 20_01
      end

      context "with a price that is too low" do
        it "raises an error" do
          expect do
            @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price, perceived_price_cents: 19_99)
          end.to raise_error Subscription::UpdateFailed, "Please enter an amount greater than or equal to the minimum."
        end
      end
    end

    context "when skip_preparing_for_charge is true" do
      it "does not call Stripe or perform any chargeable-related operations" do
        setup_subscription

        expect_any_instance_of(Purchase).not_to receive(:load_chargeable_for_charging)
        expect(Stripe::PaymentIntent).not_to receive(:create)

        @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price, skip_preparing_for_charge: true)
      end
    end

    context "when applying a quantity change" do
      before do
        setup_subscription
      end

      it "updates the purchase quantity and price" do
        @subscription.update_current_plan!(new_variants: [@subscription.tier], new_price: @subscription.price, new_quantity: 2)

        @subscription.reload
        expect(@subscription.original_purchase.displayed_price_cents).to eq 11_98
        expect(@subscription.original_purchase.quantity).to eq 2
      end
    end

    context "when applying a plan change" do
      before :each do
        setup_subscription
      end

      it "uses that price as the new price even if product price is higher" do
        @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price, perceived_price_cents: 10_00, is_applying_plan_change: true)

        expect(@subscription.reload.original_purchase.displayed_price_cents).to eq 10_00
      end

      it "uses that price as the new price even if product price is lower" do
        @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price, perceived_price_cents: 30_00, is_applying_plan_change: true)

        expect(@subscription.reload.original_purchase.displayed_price_cents).to eq 30_00
      end

      context "and free trial is enabled" do
        it "does not require the new 'original purchase' to be marked a free trial purchase" do
          @product.update!(free_trial_enabled: true, free_trial_duration_amount: 1, free_trial_duration_unit: :week)

          expect do
            @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price, perceived_price_cents: 10_00, is_applying_plan_change: true)
          end.not_to raise_error
        end
      end

      context "but product is no longer for sale" do
        it "still allows the plan to be changed" do
          @product.update!(purchase_disabled_at: 1.day.ago)
          expect do
            @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price, perceived_price_cents: 10_00, is_applying_plan_change: true)
          end.not_to raise_error

          expect(@subscription.reload.original_purchase.displayed_price_cents).to eq 10_00
        end
      end
    end

    context "when purchase has a license" do
      it "associates the license with the new original_purchase" do
        setup_subscription

        license = create(:license, purchase: @original_purchase)

        @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price)

        new_original_purchase = @subscription.reload.original_purchase
        expect(new_original_purchase.id).not_to eq @original_purchase.id
        expect(license.reload.purchase_id).to eq new_original_purchase.id
      end
    end

    context "when purchase was recommended" do
      it "charges the discover fee percentage from the original purchase instead of the current product discover fee" do
        setup_subscription(was_product_recommended: true, discover_fee_per_thousand: 300)
        @product.update!(discover_fee_per_thousand: 400)
        allow_any_instance_of(Subscription).to receive(:mor_fee_applicable?).and_return(false)

        new_purchase = @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price)
        @subscription.reload

        expect(new_purchase.fee_cents).to eq(780) # 180 (gumroad 9% fee) + 600 (discover 30% fee)

        recurring_purchase = @subscription.charge!
        expect(recurring_purchase.purchase_state).to eq "successful"
        expect(recurring_purchase.fee_cents).to eq(810)
        expect(recurring_purchase.discover_fee_per_thousand).to eq(300)
      end
    end

    context "when purchase has sent emails" do
      it "associates the emails with the new original_purchase" do
        setup_subscription

        installment = create(:installment, link: @product, seller: @product.user, published_at: Time.current)
        email_info = create(:creator_contacting_customers_email_info, installment:, purchase: @original_purchase)

        @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price)

        new_original_purchase = @subscription.reload.original_purchase
        expect(email_info.reload.purchase_id).to eq new_original_purchase.id
      end
    end

    context "when comments are associated with the purchase" do
      it "updates the comments with the new original_purchase" do
        setup_subscription

        purchase = create(:purchase, created_at: 1.second.ago)
        comment1 = create(:comment, purchase: @original_purchase)
        comment2 = create(:comment)
        comment3 = create(:comment, purchase:)
        comment4 = create(:comment, purchase: @original_purchase)

        @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price)

        new_original_purchase = @subscription.reload.original_purchase

        expect(comment1.reload.purchase_id).to eq(new_original_purchase.id)
        expect(comment2.reload.purchase_id).to be_nil
        expect(comment3.reload.purchase_id).to eq(purchase.id)
        expect(comment4.reload.purchase_id).to eq(new_original_purchase.id)
      end
    end

    context "when purchase has a URL redirect" do
      it "creates a URL redirect for the new original_purchase" do
        setup_subscription(with_product_files: true)

        @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price)

        new_original_purchase = @subscription.reload.original_purchase
        expect(new_original_purchase.id).not_to eq @original_purchase.id
        expect(new_original_purchase.url_redirect).to be
      end
    end

    context "for test subscription" do
      it "marks the new original purchase 'test_successful'" do
        setup_subscription
        @product.update!(user: @user)
        @subscription.update!(is_test_subscription: true)
        @original_purchase.update!(purchase_state: "test_successful", seller: @user)

        @subscription.update_current_plan!(new_variants: [@new_tier], new_price: @yearly_product_price)

        expect(@subscription.reload.original_purchase.purchase_state).to eq "test_successful"
      end
    end

    context "for a subscription with fixed length" do
      it "raises an error" do
        setup_subscription
        @subscription.update!(charge_occurrence_count: 4)

        expect do
          @subscription.update_current_plan!(new_variants: [@original_tier], new_price: @yearly_product_price)
        end.to raise_error(Subscription::UpdateFailed).with_message("Changing plans for fixed-length subscriptions is not currently supported.")
      end
    end

    context "for installment plans" do
      let(:installment_plan_purchase) { create(:installment_plan_purchase) }
      let(:subscription) { installment_plan_purchase.subscription }

      it "raises an error" do
        expect do
          subscription.update_current_plan!(new_variants: [], new_price: nil)
        end.to raise_error(Subscription::UpdateFailed).with_message("Installment plans cannot be updated.")
      end
    end
  end

  describe "last purchase state" do
    describe "failed" do
      before do
        travel_to(Date.today + 3) do
          @subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @product)
          purchase = create(:purchase, is_original_subscription_purchase: true, link: @product, subscription: @subscription)
          purchase.update_attribute(:purchase_state, "failed")
        end
      end
      it "within time frame is false" do
        travel_to(Date.today + 4) do
          expect(@subscription.purchases.paid.where("succeeded_at > ?", 48.hours.ago).present?).to be(false)
        end
      end
      it "outside time frame is false" do
        travel_to(Date.today + 6) do
          expect(@subscription.purchases.paid.where("succeeded_at > ?", 48.hours.ago).present?).to be(false)
        end
      end
    end
    describe "successful" do
      before do
        travel_to(Date.today + 3) do
          @subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: @product)
          purchase = create(:purchase, is_original_subscription_purchase: true, link: @product, subscription: @subscription)
          purchase.update_attribute(:succeeded_at, Time.current)
        end
      end
      it "within time frame is true" do
        travel_to(Date.today + 4) do
          expect(@subscription.purchases.paid.where("succeeded_at > ?", 48.hours.ago).present?).to be(true)
        end
      end
      it "outside time frame is false" do
        travel_to(Date.today + 6) do
          expect(@subscription.purchases.paid.where("succeeded_at > ?", 48.hours.ago).present?).to be(false)
        end
      end
    end
  end

  describe "#cancel_effective_immediately!" do
    it "sends email and sets cancelled attributes", :freeze_time do
      mailer_double = double
      allow(mailer_double).to receive(:deliver_later)
      expect(CustomerLowPriorityMailer).to receive(:subscription_product_deleted).exactly(1).times.and_return(mailer_double)

      @subscription.cancel_effective_immediately!
      expect(@subscription.user_requested_cancellation_at.to_s).to eq(Time.current.to_s)
      expect(@subscription.cancelled_at.to_s).to eq(Time.current.to_s)
      expect(@subscription.deactivated_at.to_s).to eq(Time.current.to_s)
      expect(@subscription.cancelled_by_buyer).to be(false)
    end

    it "does not send email but sets cancelled attributes if from chargeback", :freeze_time do
      expect(CustomerLowPriorityMailer).to_not receive(:subscription_product_deleted)

      @subscription.cancel_effective_immediately!(by_buyer: true)
      expect(@subscription.user_requested_cancellation_at.to_s).to eq(Time.current.to_s)
      expect(@subscription.cancelled_at.to_s).to eq(Time.current.to_s)
      expect(@subscription.deactivated_at.to_s).to eq(Time.current.to_s)
      expect(@subscription.cancelled_by_buyer).to be(true)
    end

    it "enqueues the ping job to notify seller of subscription cancellation" do
      @subscription.cancel_effective_immediately!

      expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(nil, nil, ResourceSubscription::CANCELLED_RESOURCE_NAME, @subscription.id)
    end

    it "enqueues the ping job to notify seller of subscription ending" do
      @subscription.cancel_effective_immediately!

      expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(nil, nil, ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME, @subscription.id)
    end
  end

  describe "#cancel_immediately_if_pending_cancellation!" do
    it "enqueues the ping job to notify seller of subscription ending" do
      @subscription.update!(cancelled_at: 1.day.from_now)
      @subscription.cancel_immediately_if_pending_cancellation!

      expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(nil, nil, ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME, @subscription.id)
    end
  end

  describe "#for_tier?" do
    let(:product) { create(:membership_product_with_preset_tiered_pricing) }
    let(:tier_1) { product.tiers.first }
    let(:tier_2) { product.tiers.second }
    let(:subscription) { create(:membership_purchase, link: product, variant_attributes: [tier_1]).subscription }

    it "returns true if the subscription is currently for that tier" do
      expect(subscription.for_tier?(tier_1))
    end

    it "returns true if the subscription is pending a change to that tier" do
      create(:subscription_plan_change, subscription:, tier: tier_2)
      expect(subscription.for_tier?(tier_1)).to eq true
      expect(subscription.for_tier?(tier_2)).to eq true
    end

    it "returns false if the subscription is not for that tier or pending a change to that tier" do
      expect(subscription.for_tier?(tier_2)).to eq false
    end
  end

  describe "#pending_cancellation?" do
    it "returns true if the subscription is pending cancellation" do
      @subscription.cancel!
      expect(@subscription.pending_cancellation?).to be(true)
    end

    it "returns false if the subscription has already been cancelled" do
      @subscription.cancel_effective_immediately!
      expect(@subscription.pending_cancellation?).to be(false)
    end

    it "returns false if the subscription was deactivated for some other reason" do
      @subscription.unsubscribe_and_fail!
      expect(@subscription.pending_cancellation?).to be(false)
    end

    it "returns false for a live subscription" do
      expect(@subscription.pending_cancellation?).to be(false)
    end
  end

  describe "#cancelled?" do
    it "returns true if the subscription has been cancelled" do
      @subscription.cancel_effective_immediately!
      expect(@subscription.cancelled?).to eq true
    end

    it "returns false if the subscription is pending cancellation" do
      @subscription.cancel!
      expect(@subscription.cancelled?).to eq false
    end

    it "returns true if the subscription is pending cancellation but flag to treat as cancelled is set" do
      @subscription.cancel!
      expect(@subscription.cancelled?(treat_pending_cancellation_as_live: false)).to eq true
    end

    it "returns false if the subscription was deactivated for some other reason" do
      @subscription.unsubscribe_and_fail!
      expect(@subscription.cancelled?).to eq false
    end

    it "returns false for a live subscription" do
      expect(@subscription.cancelled?).to eq false
    end
  end

  describe "#deactivated?" do
    it "returns true if the subscription has been deactivated" do
      @subscription.deactivated_at = 1.day.ago
      expect(@subscription.deactivated?).to eq true
    end

    it "returns false if the subscription has not been deactivated" do
      @subscription.deactivated_at = nil
      expect(@subscription.deactivated?).to eq false
    end
  end

  describe "#cancelled_by_seller?" do
    it "returns true for a subscription that was cancelled by the seller" do
      subscription = build(:subscription, cancelled_at: 1.day.ago, cancelled_by_buyer: false)
      expect(subscription.cancelled_by_seller?).to eq true
    end

    it "returns false for a subscription that was cancelled by the buyer" do
      subscription = build(:subscription, cancelled_at: 1.day.ago, cancelled_by_buyer: true)
      expect(subscription.cancelled_by_seller?).to eq false
    end

    it "returns false for a live subscription that is not pending cancellation" do
      subscription = build(:subscription)
      expect(subscription.cancelled_by_seller?).to eq false
    end

    it "returns false for a live subscription that is pending cancellation by buyer" do
      subscription = build(:subscription, cancelled_at: 1.week.from_now, cancelled_by_buyer: true)
      expect(subscription.cancelled_by_seller?).to eq false
    end

    it "returns true for a live subscription that is pending cancellation by seller" do
      subscription = build(:subscription, cancelled_at: 1.week.from_now, cancelled_by_buyer: false)
      expect(subscription.cancelled_by_seller?).to eq true
    end

    it "returns false for a failed subscription" do
      subscription = build(:subscription, failed_at: 1.day.ago)
      expect(subscription.cancelled_by_seller?).to eq false
    end

    it "returns false for an ended subscription" do
      subscription = build(:subscription, ended_at: 1.day.ago)
      expect(subscription.cancelled_by_seller?).to eq false
    end
  end

  describe "#pending_failure?" do
    it "returns false for a subscription in free trial" do
      purchase = create(:free_trial_membership_purchase)
      expect(purchase.subscription.pending_failure?).to eq false
    end

    it "returns false for a live subscription" do
      subscription = build(:subscription)
      expect(subscription.pending_failure?).to be_falsey
    end

    it "returns false for a failed subscription" do
      subscription = build(:subscription, failed_at: 1.day.ago)
      expect(subscription.pending_failure?).to eq false
    end

    it "returns true for a live subscription in grace period" do
      subscription = create(:subscription)
      create(:purchase, subscription:, is_original_subscription_purchase: true, purchase_state: "successful")
      travel_to 1.month.from_now
      create(:purchase, subscription:, purchase_state: "failed")

      expect(subscription.pending_failure?).to eq true
    end
  end

  describe "#status" do
    it "returns 'alive' for a live subscription" do
      subscription = build(:subscription)
      expect(subscription.status).to eq "alive"
    end

    it "returns 'pending_failure' for a subscription in a grace period" do
      subscription = create(:subscription)
      create(:purchase, subscription:, is_original_subscription_purchase: true, purchase_state: "successful")
      travel_to 1.month.from_now
      create(:purchase, subscription:, purchase_state: "failed")

      expect(subscription.status).to eq "pending_failure"
    end

    it "returns 'pending_cancellation' for a subscription pending cancellation" do
      subscription = create(:subscription, cancelled_at: 1.month.from_now)
      expect(subscription.status).to eq "pending_cancellation"
    end

    it "returns termination reason for a terminated subscription" do
      subscription = create(:subscription, failed_at: 1.day.ago, deactivated_at: 1.day.ago)
      expect(subscription.status).to eq "failed_payment"
    end
  end

  describe "#end_time_of_subscription" do
    it "is in 1 month", :freeze_time do
      purchase = create(:purchase, link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: false, subscription: @subscription)
      purchase.update!(succeeded_at: Time.current)
      expect(@subscription.end_time_of_subscription).to eq(1.month.from_now)
    end

    it "is in 3 months", :freeze_time do
      product = create(:membership_product, subscription_duration: :quarterly)
      subscription = create(:membership_purchase, link: product, succeeded_at: Time.current).subscription
      expect(subscription.end_time_of_subscription).to eq(3.months.from_now)
    end

    it "is in 6 months", :freeze_time do
      product = create(:membership_product, subscription_duration: :biannually)
      subscription = create(:membership_purchase, link: product, succeeded_at: Time.current).subscription
      expect(subscription.end_time_of_subscription).to eq(6.months.from_now)
    end

    it "is in 1 year", :freeze_time do
      product = create(:membership_product, subscription_duration: :yearly)
      subscription = create(:membership_purchase, link: product, succeeded_at: Time.current).subscription
      expect(subscription.end_time_of_subscription).to eq(1.year.from_now)
    end

    it "is in 2 years", :freeze_time do
      product = create(:membership_product, subscription_duration: :every_two_years)
      subscription = create(:membership_purchase, link: product, succeeded_at: Time.current).subscription
      expect(subscription.end_time_of_subscription).to eq(2.years.from_now)
    end

    it "is the most recent ended time for test subscription", :freeze_time do
      product = create(:membership_product, subscription_duration: :quarterly)
      subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: product, is_test_subscription: true)
      purchase = create(:purchase, link: product, price_cents: product.price_cents, is_original_subscription_purchase: true, state: "test_successful",
                                   subscription:, succeeded_at: Time.current)
      purchase.update!(succeeded_at: Time.current)
      expect(subscription.end_time_of_subscription).to eq(Time.current)
    end

    it "is Time.current for test subscription without succeeded_at set", :freeze_time do
      product = create(:membership_product, subscription_duration: :quarterly)
      subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: product, is_test_subscription: true)
      create(:purchase, link: product, price_cents: product.price_cents, is_original_subscription_purchase: true, state: "test_successful",
                        subscription:)
      expect(subscription.end_time_of_subscription).to eq(Time.current)
    end

    it "is Time.current when there are no successful purchases", :freeze_time do
      product = create(:membership_product, subscription_duration: :quarterly)
      subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: product)
      create(:purchase, link: product, price_cents: product.price_cents, is_original_subscription_purchase: true,
                        subscription:, purchase_state: "in_progress")
      expect(subscription.end_time_of_subscription).to eq(Time.current)
    end

    context "when the subscription has a free trial" do
      before do
        purchase = create(:free_trial_membership_purchase)
        @subscription = purchase.subscription
      end

      context "during the free trial" do
        it "returns the time the free trial ends" do
          expect(@subscription.end_time_of_subscription).to eq @subscription.free_trial_ends_at
        end
      end

      context "after the free trial" do
        it "returns the time the free trial ends" do
          travel_to(1.week.from_now) do
            expect(@subscription.end_time_of_subscription).to eq @subscription.free_trial_ends_at
          end
        end
      end
    end

    describe "refunds and chargebacks" do
      context "when the last purchase was refunded or chargedback" do
        let(:purchase) { create(:membership_purchase) }
        let(:subscription) { purchase.subscription }

        it "returns the current time if it is the only purchase", :freeze_time do
          purchase.update!(stripe_refunded: true)
          expect(subscription.end_time_of_subscription).to eq Time.current

          purchase.update!(stripe_refunded: false, chargeback_date: 1.day.ago)
          expect(subscription.end_time_of_subscription).to eq Time.current
        end

        it "returns the current time if the last paid period has lapsed" do
          end_time = purchase.succeeded_at + subscription.period
          later_purchase = create(:purchase, subscription:, link: subscription.link, stripe_refunded: true)
          expect(subscription.end_time_of_subscription).to eq end_time

          later_purchase.update!(stripe_refunded: false, chargeback_date: 1.day.ago)
          expect(subscription.end_time_of_subscription).to eq end_time
        end

        context "but a prior purchase covers the current time" do
          it "returns the end time based on that prior purchase" do
            end_time = purchase.succeeded_at + subscription.period
            later_purchase = create(:purchase, subscription:, link: subscription.link, stripe_refunded: true)
            expect(subscription.end_time_of_subscription).to eq end_time

            later_purchase.update!(stripe_refunded: false, chargeback_date: 1.day.ago)
            expect(subscription.end_time_of_subscription).to eq end_time
          end
        end
      end
    end
  end

  describe "#send_renewal_reminders?" do
    it "returns false when feature `membership_renewal_reminders` is disabled" do
      setup_subscription(recurrence: BasePrice::Recurrence::QUARTERLY)

      expect(@subscription.send_renewal_reminders?).to be(false)
    end

    it "returns true when feature `membership_renewal_reminders` is enabled" do
      setup_subscription(recurrence: BasePrice::Recurrence::QUARTERLY)

      Feature.activate_user(:membership_renewal_reminders, @subscription.seller)

      expect(@subscription.send_renewal_reminders?).to be(true)
    end
  end

  describe "#send_renewal_reminder_at" do
    context "when the subscription is monthly" do
      it "returns one day prior" do
        setup_subscription(recurrence: BasePrice::Recurrence::MONTHLY)
        travel_to(Time.current) do
          @original_purchase.update!(succeeded_at: Time.current)
          expect(@subscription.send_renewal_reminder_at).to eq(1.month.from_now - 1.day)
        end
      end
    end

    context "when the subscription is quarterly" do
      it "returns seven days prior" do
        setup_subscription(recurrence: BasePrice::Recurrence::QUARTERLY)
        travel_to(Time.current) do
          @original_purchase.update!(succeeded_at: Time.current)
          expect(@subscription.send_renewal_reminder_at).to eq(3.months.from_now - 7.days)
        end
      end
    end

    context "when the subscription is yearly" do
      it "returns seven days prior" do
        setup_subscription(recurrence: BasePrice::Recurrence::YEARLY)
        travel_to(Time.current) do
          @original_purchase.update!(succeeded_at: Time.current)
          expect(@subscription.send_renewal_reminder_at).to eq(1.year.from_now - 7.days)
        end
      end
    end

    context "when the subscription is every two years" do
      it "returns seven days prior" do
        setup_subscription(recurrence: BasePrice::Recurrence::EVERY_TWO_YEARS)
        travel_to(Time.current) do
          @original_purchase.update!(succeeded_at: Time.current)
          expect(@subscription.send_renewal_reminder_at).to eq(2.years.from_now - 7.days)
        end
      end
    end
  end

  describe "#end_time_of_last_paid_period" do
    before do
      @last_successful_purchase_at = Time.utc(2020, 2, 1)
      @original_purchase = create(:membership_purchase, succeeded_at: Time.utc(2020, 1, 1))
      @subscription = @original_purchase.subscription
      create(:purchase, subscription: @subscription, succeeded_at: Time.utc(2020, 3, 1), stripe_refunded: true)
      create(:purchase, subscription: @subscription, succeeded_at: Time.utc(2020, 4, 1), purchase_state: "failed")
      create(:purchase, subscription: @subscription, succeeded_at: Time.utc(2020, 6, 1), chargeback_date: Time.utc(2020, 6, 1))
    end

    it "returns the paid-through time of the most recent successful, not charged back, fully refunded, or deleted purchase" do
      create(:purchase, subscription: @subscription, succeeded_at: @last_successful_purchase_at)
      expect(@subscription.reload.end_time_of_last_paid_period).to eq @last_successful_purchase_at + @subscription.period
    end

    it "returns the paid-through time of a partially refunded purchase if that is the most recent successful purchase" do
      create(:purchase, subscription: @subscription, stripe_partially_refunded: true, succeeded_at: @last_successful_purchase_at)
      expect(@subscription.end_time_of_last_paid_period).to eq @last_successful_purchase_at + @subscription.period
    end

    it "returns the paid-through time of a chargedback purchase if that is the most recent successful purchase and the chargeback was reversed" do
      create(:purchase, subscription: @subscription, chargeback_date: 5.months.ago, chargeback_reversed: true, succeeded_at: @last_successful_purchase_at)
      expect(@subscription.end_time_of_last_paid_period).to eq @last_successful_purchase_at + @subscription.period
    end

    it "returns the free trial termination time if there are no successful charges" do
      @original_purchase.update!(purchase_state: "not_charged", succeeded_at: nil)
      free_trial_ends_at = @original_purchase.created_at + 1.week
      @subscription.update!(free_trial_ends_at:)

      expect(@subscription.reload.end_time_of_last_paid_period).to eq free_trial_ends_at
    end
  end

  describe "#last_successful_charge_at" do
    context "when there are successful purchases" do
      it "returns the succeeded_at time of the most recent successful purchase" do
        subscription = create(:subscription)
        purchase = create(:purchase, subscription:, is_original_subscription_purchase: true, succeeded_at: Time.current)

        expect(subscription.last_successful_charge_at).to eq purchase.succeeded_at
      end
    end

    context "when there are successful test purchases" do
      it "returns the succeeded_at time of the most recent successful purchase" do
        subscription = create(:subscription, is_test_subscription: true)
        create(:purchase, subscription:, is_original_subscription_purchase: true, purchase_state: "test_successful", succeeded_at: 1.day.ago)
        purchase = create(:purchase, subscription:, purchase_state: "test_successful", succeeded_at: Time.current)

        expect(subscription.last_successful_charge_at).to eq purchase.succeeded_at
      end
    end

    context "when there are no successful purchases" do
      it "returns nil" do
        subscription = create(:subscription)
        subscription.purchases.update_all(succeeded_at: nil)

        expect(subscription.last_successful_charge_at).to be_nil
      end
    end
  end

  describe "#overdue_for_charge?" do
    before :each do
      @purchase = create(:membership_purchase)
      @subscription = @purchase.subscription
    end

    context "before the end of the subscription period" do
      it "returns false" do
        expect(@subscription.overdue_for_charge?).to eq false
      end
    end

    context "after the end of the subscription period" do
      it "returns true" do
        travel_to(1.month.from_now + 1.day) do
          expect(@subscription.overdue_for_charge?).to eq true
        end
      end
    end

    context "when there are no successful purchases" do
      it "returns true" do
        @purchase.update!(purchase_state: "failed")
        expect(@subscription.reload.overdue_for_charge?).to eq true
      end
    end

    context "for a subscription with a free trial" do
      before do
        @purchase.update!(purchase_state: "not_charged", is_free_trial_purchase: true)
      end

      context "during the free trial" do
        it "returns false" do
          @subscription.update!(free_trial_ends_at: 1.day.from_now)
          expect(@subscription.reload.overdue_for_charge?).to eq false
        end
      end

      context "after the free trial" do
        it "returns true" do
          @subscription.update!(free_trial_ends_at: 1.day.ago)
          expect(@subscription.reload.overdue_for_charge?).to eq true
        end
      end
    end
  end

  describe "#seconds_overdue_for_charge" do
    before :each do
      @purchase = create(:membership_purchase, succeeded_at: 1.hour.ago)
      @subscription = @purchase.subscription
    end

    it "returns 0 for currently active subscriptions" do
      expect(@subscription.seconds_overdue_for_charge).to eq 0
    end

    it "returns 0 for a subscription with no successful purchases" do
      @purchase.update!(purchase_state: "failed")
      expect(@subscription.seconds_overdue_for_charge).to eq 0
    end

    it "returns the seconds overdue for charge for a subscription overdue for a charge" do
      travel_to @purchase.succeeded_at + 1.month + 43.seconds do
        expect(@subscription.seconds_overdue_for_charge).to eq 43
      end
    end
  end

  describe "#has_a_charge_in_progress?" do
    it "returns true if there's an associated purchase in progress otherwise returns false" do
      purchase = create(:membership_purchase, succeeded_at: 1.hour.ago)
      subscription = purchase.subscription
      create(:recurring_membership_purchase, subscription:, purchase_state: "failed")

      expect(subscription.has_a_charge_in_progress?).to be false

      in_progress_purchase = create(:recurring_membership_purchase, subscription:, purchase_state: "in_progress")
      expect(subscription.has_a_charge_in_progress?).to be true

      in_progress_purchase.update!(purchase_state: "successful")
      expect(subscription.has_a_charge_in_progress?).to be false
    end
  end

  describe "#prorated_discount_price_cents" do
    before :each do
      @succeeded_at = Time.utc(2020, 04, 01)
      product = create(:membership_product_with_preset_tiered_pricing)
      tier = product.default_tier
      tier_price = tier.prices.find_by(recurrence: BasePrice::Recurrence::MONTHLY) # $3.00
      @subscription = create(:subscription, link: product)
      @purchase = create(:purchase, subscription: @subscription,
                                    is_original_subscription_purchase: true,
                                    succeeded_at: @succeeded_at,
                                    price_cents: tier_price.price_cents)
    end

    context "when there are no successful purchases" do
      it "returns 0" do
        @subscription.purchases.update_all(succeeded_at: nil)
        expect(@subscription.prorated_discount_price_cents).to eq 0
      end
    end

    context "before the start of the subscription period" do
      it "returns the full price" do
        expect(
          @subscription.prorated_discount_price_cents(calculate_as_of: @succeeded_at - 1.minute)
        ).to eq 300
      end
    end

    context "halfway through the subscription period" do
      it "returns half the price" do
        calculate_as_of = @succeeded_at + @subscription.current_billing_period_seconds / 2
        expect(
          @subscription.prorated_discount_price_cents(calculate_as_of:)
        ).to eq 150
      end
    end

    context "after the end of the subscription period" do
      it "returns 0" do
        expect(
          @subscription.prorated_discount_price_cents(calculate_as_of: Time.utc(2020, 05, 02))
        ).to eq 0
      end
    end

    context "when the month has less than 30 days" do
      before do
        @succeeded_at = Time.utc(2021, 02, 01)
        @purchase.update!(succeeded_at: @succeeded_at)
      end

      context "halfway through the subscription period" do
        it "returns half the price" do
          expect(
            @subscription.prorated_discount_price_cents(calculate_as_of: @succeeded_at + 2.weeks)
          ).to eq 150
        end
      end

      context "after the end of the month" do
        it "returns 0" do
          expect(
            @subscription.prorated_discount_price_cents(calculate_as_of: Time.utc(2021, 03, 01))
          ).to eq 0
        end
      end
    end
  end

  describe "#current_billing_period_seconds" do
    let(:seconds_per_day) { 24 * 60 * 60 }

    context "for a monthly subscription" do
      it "returns the correct number of seconds in a 28 day month" do
        purchase = create(:membership_purchase, succeeded_at: Time.utc(2021, 02, 01))
        expect(purchase.subscription.current_billing_period_seconds).to eq 28 * seconds_per_day
      end

      it "returns the correct number of seconds in a 29 day month" do
        purchase = create(:membership_purchase, succeeded_at: Time.utc(2020, 02, 01))
        expect(purchase.subscription.current_billing_period_seconds).to eq 29 * seconds_per_day
      end

      it "returns the correct number of seconds in a 30 day month" do
        purchase = create(:membership_purchase, succeeded_at: Time.utc(2021, 04, 01))
        expect(purchase.subscription.current_billing_period_seconds).to eq 30 * seconds_per_day
      end

      it "returns the correct number of seconds in a 31 day month" do
        purchase = create(:membership_purchase, succeeded_at: Time.utc(2021, 01, 01))
        expect(purchase.subscription.current_billing_period_seconds).to eq 31 * seconds_per_day
      end
    end

    context "for a quarterly subscription" do
      let(:product) do
        create(:membership_product_with_preset_tiered_pricing,
               subscription_duration: "quarterly",
               recurrence_price_values: [
                 { "quarterly": { enabled: true, price: 3 } },
                 { "quarterly": { enabled: true, price: 5 } }
               ])
      end

      it "returns the correct number of seconds for a subscription starting in January" do
        purchase = create(:membership_purchase, link: product, succeeded_at: Time.utc(2021, 01, 01))
        expect(purchase.subscription.current_billing_period_seconds).to eq (31 + 28 + 31) * seconds_per_day
      end

      it "returns the correct number of seconds for a subscription starting in June" do
        purchase = create(:membership_purchase, link: product, succeeded_at: Time.utc(2021, 06, 01))
        expect(purchase.subscription.current_billing_period_seconds).to eq (30 + 31 + 31) * seconds_per_day
      end
    end

    context "with no successful charges" do
      it "returns 0" do
        subscription = create(:subscription)
        expect(subscription.current_billing_period_seconds).to eq 0
      end
    end

    context "during a free trial" do
      it "returns the duration of the free trial" do
        purchased_at = Time.utc(2021, 01, 01)
        purchase = create(:free_trial_membership_purchase, created_at: purchased_at)
        subscription = purchase.subscription
        subscription.update!(free_trial_ends_at: purchased_at + 1.week)

        expect(subscription.current_billing_period_seconds).to eq 7 * seconds_per_day
      end
    end
  end

  describe "#termination_reason" do
    let(:terminated_at) { Date.new(2020, 1, 1) }

    it "returns the correct reason if subscription ended due to fixed period ending" do
      subscription = build(:subscription, ended_at: terminated_at, deactivated_at: terminated_at)
      expect(subscription.termination_reason).to eq "fixed_subscription_period_ended"
    end

    it "returns the correct reason if subscription was cancelled" do
      subscription = build(:subscription, cancelled_at: terminated_at, deactivated_at: terminated_at)
      expect(subscription.termination_reason).to eq "cancelled"
    end

    it "returns the correct reason if subscription was cancelled due to failed payments" do
      subscription = build(:subscription, failed_at: terminated_at, deactivated_at: terminated_at)
      expect(subscription.termination_reason).to eq "failed_payment"
    end

    it "returns nil if the subscription does not have a termination time set" do
      subscription = build(:subscription)
      expect(subscription.termination_reason).to be_nil
    end
  end

  describe "payment options" do
    before do
      @user = create(:user, credit_card: create(:credit_card))
    end

    context "for a non-tiered membership subscription" do
      it "has the proper payment option" do
        product = create(:subscription_product)
        subscription = create(:subscription, link: product, user: @user, created_at: 3.days.ago)
        create(:purchase, is_original_subscription_purchase: true, link: product, subscription:, purchaser: @user)

        expect(subscription.payment_options.count).to eq 1
        payment_option = subscription.payment_options.last
        expect(payment_option.price).to eq product.prices.alive.is_buy.last
      end
    end

    context "for a tiered membership subscription" do
      it "has the proper payment option" do
        product = create(:membership_product)
        subscription = create(:subscription, link: product, user: @user, created_at: 3.days.ago)
        create(:purchase, is_original_subscription_purchase: true, link: product, subscription:, purchaser: @user)

        expect(subscription.payment_options.count).to eq 1
        payment_option = subscription.payment_options.last
        expect(payment_option.price).to eq product.prices.alive.is_buy.last
      end
    end
  end

  describe "#expected_completion_time", :freeze_time do
    let(:t0) { Time.utc(2023, 1, 1, 12, 0, 0) }

    it "returns nil for non fixed-length subscriptions" do
      purchase = create(:membership_purchase)
      subscription = purchase.subscription

      expect(subscription.expected_completion_time).to be_nil
    end

    context "for fixed-length monthly memberships" do
      it "calculates end_of_last_paid_period + period * remaining when some charges completed" do
        travel_to(t0)

        purchase = create(:membership_purchase, succeeded_at: t0)
        subscription = purchase.subscription
        subscription.update!(charge_occurrence_count: 3)

        expected = purchase.succeeded_at + 3.months
        expect(subscription.expected_completion_time).to eq(expected)
      end

      it "considers free_trial_ends_at during the free trial" do
        travel_to(t0)

        free_trial_purchase = create(:free_trial_membership_purchase, created_at: t0)
        subscription = free_trial_purchase.subscription
        subscription.update!(charge_occurrence_count: 3)

        expected = subscription.free_trial_ends_at + 3.months
        expect(subscription.expected_completion_time).to eq(expected)
      end

      it "equals end_of_last_paid_period when all required charges are completed" do
        travel_to(t0)

        purchase = create(:membership_purchase, succeeded_at: t0)
        subscription = purchase.subscription
        subscription.update!(charge_occurrence_count: 3)

        create(:purchase, subscription:, link: subscription.link, succeeded_at: t0 + 1.month)
        create(:purchase, subscription:, link: subscription.link, succeeded_at: t0 + 2.months)

        expect(subscription.charges_completed?).to eq(true)
        expect(subscription.expected_completion_time).to eq(subscription.end_time_of_last_paid_period)
      end
    end
  end

  describe "#has_fixed_length?" do
    it "returns true if charge_occurrence_count is set" do
      subscription = build(:subscription, charge_occurrence_count: 1)
      expect(subscription.has_fixed_length?).to eq true
    end

    it "returns false if charge_occurrence_count is not set" do
      subscription = build(:subscription)
      expect(subscription.has_fixed_length?).to eq false
    end
  end

  describe "#charges_completed?" do
    before do
      product = create(:membership_product)
      @subscription = create(:subscription, link: product)
      create(:purchase, is_original_subscription_purchase: true, link: product, subscription: @subscription, purchaser: @subscription.user)
      create(:purchase, link: product, subscription: @subscription, purchaser: @subscription.user, purchase_state: "failed")
    end

    it "returns `true` when the required number of charges are processed" do
      @subscription.update_columns(charge_occurrence_count: 2)

      create(:purchase, link: @subscription.link, subscription: @subscription, purchaser: @subscription.user)
      expect(@subscription.charges_completed?).to be(true)
    end

    it "returns `false` when the required number of charges are not processed" do
      @subscription.update_columns(charge_occurrence_count: 2)

      expect(@subscription.charges_completed?).to be(false)
    end

    it "returns `false` when the subscription has no set number of charges" do
      expect(@subscription.charges_completed?).to be(false)
    end
  end

  describe "#price" do
    it "uses the last_payment_option_id column if it's not nil" do
      payment_option = create(:payment_option)
      subscription = create(:subscription)
      subscription.payment_options.delete_all
      subscription.update_columns(last_payment_option_id: payment_option.id)
      expect(subscription.reload.price).to eq(payment_option.price)
    end

    it "uses the 'payment_options.alive.last' query if last_payment_option is nil" do
      subscription = create(:subscription)
      subscription.update_columns(last_payment_option_id: nil)
      expect(subscription.price).to eq(subscription.payment_options.alive.last.price)
    end
  end

  describe "#current_subscription_price_cents" do
    context "when the subscription doesn't have an offer code with a limited duration" do
      it "returns the original purchase displayed price" do
        @subscription.original_purchase.update!(displayed_price_cents: 1234)
        expect(@subscription.current_subscription_price_cents).to eq 1234
      end
    end

    context "when the subscription has an offer code with a limited duration" do
      let(:offer_code) { create(:offer_code, products: [@product], amount_cents: 100, duration_in_billing_cycles: 1) }

      before do
        @purchase.update!(offer_code: @offer_code, displayed_price_cents: 900)
        @purchase.create_purchase_offer_code_discount!(offer_code:, offer_code_amount: 100, offer_code_is_percent: false, pre_discount_minimum_price_cents: 1000, duration_in_billing_cycles: 1)
        @subscription.reload
      end

      context "when the discount's duration has elapsed" do
        it "returns the original purchase's displayed price before discount" do
          expect(@subscription.current_subscription_price_cents).to eq(1000)
        end
      end

      context "when the discount's duration has not elapsed" do
        before do
          @purchase.purchase_offer_code_discount.update!(duration_in_billing_cycles: 2)
        end

        it "returns the original purchase's displayed price" do
          expect(@subscription.current_subscription_price_cents).to eq(900)
        end
      end
    end

    context "installment plans" do
      let!(:product) { create(:product, name: "Awesome product", user: seller, price_cents: 1000) }
      let!(:installment_plan) { create(:product_installment_plan, link: product, number_of_installments: 3) }
      let!(:subscription) { create(:subscription, link: product, is_installment_plan: true) }

      context "no discounts" do
        let!(:purchase) { create(:installment_plan_purchase, subscription:, link: product) }

        it "returns the next installment price" do
          expect(purchase.price_cents).to eq(334)
          expect(subscription.current_subscription_price_cents).to eq(333)
        end

        it "returns the last installment price when the installment plan is completed" do
          create(:recurring_installment_plan_purchase, subscription:, link: product)
          create(:recurring_installment_plan_purchase, subscription:, link: product)

          expect(subscription.charges_completed?).to eq(true)
          expect(subscription.current_subscription_price_cents).to eq(333)
        end
      end

      context "with a discount" do
        let!(:offer_code) { create(:offer_code, products: [product], amount_cents: 100, duration_in_billing_cycles: 1) }
        let!(:purchase) { create(:installment_plan_purchase, subscription:, link: product, offer_code:) }

        it "applies to all installments even if it's only for one membership cycle" do
          expect(purchase.price_cents).to eq(300)
          expect(subscription.current_subscription_price_cents).to eq(300)
        end
      end
    end
  end

  describe "#current_plan_displayed_price_cents" do
    context "non-tiered memberships" do
      it "returns the original purchase displayed price" do
        @subscription.original_purchase.update!(displayed_price_cents: 1234)
        expect(@subscription.reload.current_subscription_price_cents).to eq 1234
      end
    end

    context "tiered memberships" do
      before do
        @product = create(:membership_product_with_preset_tiered_pricing)
        @tier = @product.default_tier
        @tier_price = @tier.prices.find_by(recurrence: BasePrice::Recurrence::MONTHLY) # $3.00
        @subscription = create(:subscription, link: @product)
        @purchase = create(:purchase, subscription: @subscription,
                                      is_original_subscription_purchase: true,
                                      price_cents: @tier_price.price_cents)
      end

      context "non-PWYW tier" do
        it "returns the original purchase displayed price" do
          @subscription.original_purchase.update!(displayed_price_cents: 1234)
          expect(@subscription.current_subscription_price_cents).to eq 1234
        end
      end

      context "PWYW tier" do
        before do
          @tier.update!(customizable_price: true)
          @original_price = @tier_price.price_cents
          @new_price = @original_price - 100
        end

        it "returns the tier minimum price if it is lower than the current subscription price" do
          @tier_price.update!(price_cents: @new_price)
          expect(@subscription.current_subscription_price_cents).to eq @original_price
        end

        it "returns the current subscription price if it is lower than the tier price" do
          @subscription.original_purchase.update!(displayed_price_cents: @new_price)
          expect(@subscription.current_subscription_price_cents).to eq @new_price
        end
      end

      context "with offer code" do
        before do
          @offer_code = create(:offer_code, products: [@product], amount_cents: 100)
          @purchase.update!(offer_code: @offer_code)
          @subscription.reload
        end

        context "when the purchase has cached offer code details" do
          it "returns the cached pre-discount price" do
            @purchase.create_purchase_offer_code_discount(offer_code: @offer_code, offer_code_amount: 50, offer_code_is_percent: true, pre_discount_minimum_price_cents: 500)
            expect(@subscription.current_plan_displayed_price_cents).to eq 500
          end
        end

        context "when the purchase does not have cached offer code details" do
          it "uses the existing offer code to calculate the pre-discount cost" do
            expect(@subscription.current_plan_displayed_price_cents).to eq 400 # $3 paid price + $1 discount
          end

          context "and the offer code is 100% off" do
            it "falls back to the purchase displayed price" do
              @offer_code.update!(amount_cents: 0, amount_percentage: 100)
              @purchase.update!(displayed_price_cents: 0)
              expect(@subscription.current_plan_displayed_price_cents).to eq 0
            end
          end
        end
      end
    end
  end

  describe "#resubscribe!" do
    it "restarts subscription if it is pending cancellation" do
      @subscription.cancel!
      expect(@subscription.pending_cancellation?).to be(true)

      @subscription.resubscribe!

      expect(@subscription.alive?(include_pending_cancellation: false)).to be(true)
    end

    it "restarts subscription if it is cancelled" do
      @subscription.cancel_effective_immediately!

      @subscription.resubscribe!

      expect(@subscription.alive?(include_pending_cancellation: false)).to be(true)
    end

    it "creates a subscription restarted event when resubscribing", :freeze_time do
      @subscription.cancel_effective_immediately!

      expect do
        @subscription.resubscribe!
        expect(@subscription.reload.subscription_events.restarted.last.occurred_at).to eq Time.current
      end.to change { @subscription.reload.subscription_events.restarted.count }.from(0).to(1)
    end

    it "restarts subscription if it has failed" do
      @subscription.unsubscribe_and_fail!

      @subscription.resubscribe!

      expect(@subscription.alive?(include_pending_cancellation: false)).to be(true)
    end

    it "does not restart subscription if has ended" do
      @subscription.end_subscription!

      @subscription.resubscribe!

      expect(@subscription.alive?(include_pending_cancellation: false)).to be(false)
    end

    it "returns true if new charge is not needed" do
      @subscription.cancel!
      expect(@subscription.pending_cancellation?).to be(true)

      expect(@subscription.resubscribe!).to be(true)
      expect(@subscription.alive?(include_pending_cancellation: false)).to be(true)
    end

    it "returns false if new charge is needed" do
      @subscription.unsubscribe_and_fail!

      expect(@subscription.resubscribe!).to be(false)
      expect(@subscription.alive?(include_pending_cancellation: false)).to be(true)
    end

    it "enqueues activate integrations worker if subscription had been deactivated" do
      @subscription.cancel_effective_immediately!
      @subscription.resubscribe!
      expect(ActivateIntegrationsWorker).to have_enqueued_sidekiq_job(@subscription.original_purchase.id)
    end

    it "does not enqueue activate integrations worker if subscription had not been deactivated" do
      @subscription.cancel!
      @subscription.resubscribe!
      expect(ActivateIntegrationsWorker.jobs.size).to eq(0)
    end

    it "creates a subscription_event of type restarted" do
      @subscription.cancel_effective_immediately!
      expect do
        @subscription.resubscribe!
        expect(@subscription.reload.subscription_events.last.event_type).to eq("restarted")
      end.to change { @subscription.reload.subscription_events.restarted.count }.from(0).to(1)
    end

    describe "workflows" do
      context "when the subscription has lapsed" do
        it "schedules any workflow installments that were missed during the lapsed period" do
          resubscribed_after_interval = 1.hour

          freeze_time do
            @subscription.cancel_effective_immediately!
          end

          expect_any_instance_of(Purchase).to receive(:reschedule_workflow_installments).with(send_delay: resubscribed_after_interval).and_call_original

          travel_to(resubscribed_after_interval.from_now) do
            @subscription.resubscribe!
          end
        end
      end

      context "when the subscription is pending cancellation" do
        it "does not schedule any workflow installments" do
          @subscription.cancel!

          original_purchase = @subscription.original_purchase
          expect(original_purchase).not_to receive(:reschedule_workflow_installments)

          @subscription.resubscribe!
        end
      end
    end
  end

  describe "#send_restart_notifications!" do
    it "notifies the creator if the subscription had been terminated" do
      @subscription.cancel!

      mail_double = double
      allow(mail_double).to receive(:deliver_later)
      allow(ContactingCreatorMailer).to receive(:subscription_restarted).and_return(mail_double)

      @subscription.resubscribe!
      @subscription.send_restart_notifications!

      expect(ContactingCreatorMailer).to have_received(:subscription_restarted).with(@subscription.id)
    end

    it "notifies the customer if the subscription had been terminated" do
      @subscription.cancel!

      mail_double = double
      allow(mail_double).to receive(:deliver_later)
      allow(CustomerMailer).to receive(:subscription_restarted).and_return(mail_double)

      @subscription.resubscribe!
      @subscription.send_restart_notifications!("payment issue resolved")

      expect(CustomerMailer).to have_received(:subscription_restarted).with(@subscription.id, "payment issue resolved")
    end

    it "sends a subscription_restarted notification if the subscription had been terminated" do
      @subscription.cancel!

      mail_double = double
      allow(mail_double).to receive(:deliver_later)
      allow(CustomerMailer).to receive(:subscription_restarted).and_return(mail_double)

      @subscription.resubscribe!
      @subscription.send_restart_notifications!

      expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(nil, nil, ResourceSubscription::SUBSCRIPTION_RESTARTED_RESOURCE_NAME, @subscription.id, hash_including("restarted_at"))
    end
  end

  describe "#last_resubscribed_at", :freeze_time do
    before do
      @subscription.subscription_events.create!(event_type: :deactivated, occurred_at: 1.week.ago)
    end

    it "returns the last restart time if the subscription has been restarted" do
      last_restart = 3.weeks.ago
      @subscription.subscription_events.create!(event_type: :restarted, occurred_at: last_restart)
      @subscription.subscription_events.create!(event_type: :restarted, occurred_at: 5.weeks.ago)

      expect(@subscription.last_resubscribed_at).to eq last_restart
    end

    it "returns nil if the subscription has not been restarted" do
      expect(@subscription.last_resubscribed_at).to be_nil
    end
  end

  describe "#last_deactivated_at", :freeze_time do
    before do
      @subscription.subscription_events.create!(event_type: :restarted, occurred_at: 1.week.ago)
    end

    it "returns the last deactivation time if the subscription has been deactivated" do
      last_deactivation = 3.weeks.ago
      @subscription.subscription_events.create!(event_type: :deactivated, occurred_at: last_deactivation)
      @subscription.subscription_events.create!(event_type: :deactivated, occurred_at: 5.weeks.ago)

      expect(@subscription.last_deactivated_at).to eq last_deactivation
    end

    it "returns nil if the subscription has not been deactivated" do
      expect(@subscription.last_deactivated_at).to be_nil
    end
  end

  describe "#resubscribed?" do
    subject { @subscription.resubscribed? }

    context "when the subscription has not had an interruption" do
      it { is_expected.to eq(false) }
    end

    context "when the subscription has had an interruption" do
      before do
        @subscription.subscription_events.create!(event_type: :deactivated, occurred_at: 1.week.ago)
        @subscription.subscription_events.create!(event_type: :restarted, occurred_at: Time.current)
      end

      it { is_expected.to eq(true) }
    end
  end

  describe "#custom_fields" do
    it "returns the custom fields on the original purchase" do
      sub = create(:subscription)
      archived_original_purchase = create(:membership_purchase, subscription: sub)
      archived_original_purchase.purchase_custom_fields << build(:purchase_custom_field, name: "name", value: "Amy")
      original_purchase = create(:membership_purchase, subscription: sub)
      original_purchase.purchase_custom_fields << build(:purchase_custom_field, name: "name", value: "Barbara")
      archived_original_purchase.update!(is_archived_original_subscription_purchase: true)
      renewal_purchase = create(:membership_purchase, subscription: sub, is_original_subscription_purchase: false)
      renewal_purchase.purchase_custom_fields << build(:purchase_custom_field, name: "name", value: "Carol")
      sub.reload
      expect(sub.custom_fields).to eq([{ name: "name", value: "Barbara", type: CustomField::TYPE_TEXT }])

      original_purchase.purchase_custom_fields.destroy_all
      expect(sub.reload.custom_fields).to eq([])
    end
  end

  describe "#has_free_trial?" do
    it "returns true if free_trial_ends_at is set" do
      subscription = build(:subscription, free_trial_ends_at: 1.day.ago)
      expect(subscription.has_free_trial?).to eq true
    end

    it "returns false if free_trial_ends_at is not set" do
      subscription = build(:subscription, free_trial_ends_at: nil)
      expect(subscription.has_free_trial?).to eq false
    end
  end

  describe "#should_exclude_product_review_on_charge_reversal?" do
    it "returns false if the subscription does not have a free trial" do
      subscription = create(:membership_purchase).subscription
      expect(subscription.should_exclude_product_review_on_charge_reversal?).to eq false
    end

    context "for a free trial subscription" do
      let(:original_purchase) { create(:free_trial_membership_purchase, should_exclude_product_review: false) }
      let(:subscription) { original_purchase.subscription }

      it "returns true if the initial successful charge does not allow a review" do
        create(:purchase, subscription:, stripe_refunded: true)
        expect(subscription.should_exclude_product_review_on_charge_reversal?).to eq true
      end

      it "returns false if the initial successful charge does not allow a review but the original purchase already excludes reviews" do
        original_purchase.update!(should_exclude_product_review: true)
        create(:purchase, subscription:, stripe_refunded: true)
        expect(subscription.reload.should_exclude_product_review_on_charge_reversal?).to eq false
      end

      it "returns false if the initial successful charge does allow a review" do
        create(:purchase, subscription:)
        expect(subscription.should_exclude_product_review_on_charge_reversal?).to eq false
      end

      it "returns true if there is not yet a successful charge" do
        expect(subscription.should_exclude_product_review_on_charge_reversal?).to eq true
      end
    end
  end

  describe "#alive_or_restartable??" do
    it "returns true if ended_at is not set and the subscription is not cancelled by the seller" do
      subscription = create(:subscription)

      expect(subscription.alive_or_restartable?).to eq(true)
    end

    it "returns true if ended_at is not set and the subscription is cancelled by the buyer" do
      subscription = create(:subscription, cancelled_at: 1.day.ago, cancelled_by_buyer: true)

      expect(subscription.alive_or_restartable?).to eq(true)
    end

    it "returns false if ended_at is set" do
      subscription = create(:subscription, ended_at: 1.day.ago)

      expect(subscription.alive_or_restartable?).to eq(false)
    end

    it "returns false if the subscription is cancelled by the seller" do
      subscription = create(:subscription, cancelled_at: 1.day.ago, cancelled_by_buyer: false)

      expect(subscription.alive_or_restartable?).to eq(false)
    end
  end

  describe "#alive_at?" do
    let(:purchase) { create(:membership_purchase, created_at: 2.days.ago) }
    let(:subscription) { purchase.subscription }
    let(:purchase_date) { subscription.true_original_purchase.created_at }

    context "no subscription events have been created" do
      context "subscription is not deactivated" do
        it "returns true if the time is after created_at" do
          expect(subscription.alive_at?(purchase_date + 1.day)).to eq true
          expect(subscription.alive_at?(purchase_date - 1.day)).to eq false
        end
      end

      context "subscription is deactivated" do
        it "returns true if the time is between created_at..deactivated_at" do
          subscription.update!(deactivated_at: purchase_date + 1.month)
          expect(subscription.alive_at?(purchase_date + 1.week)).to eq true
          expect(subscription.alive_at?(subscription.deactivated_at + 2.months)).to eq false
        end
      end
    end

    context "subscription has been deactivated and resubscribed" do
      it "returns true if the time is between subscribe and deactivate events" do
        create(:subscription_event, subscription:, event_type: :deactivated, occurred_at: purchase_date + 2.months)
        create(:subscription_event, subscription:, event_type: :restarted, occurred_at: purchase_date + 6.months)
        create(:subscription_event, subscription:, event_type: :deactivated, occurred_at: purchase_date + 12.months)

        expect(subscription.alive_at?(purchase_date + 1.month)).to eq true
        expect(subscription.alive_at?(purchase_date + 3.months)).to eq false
        expect(subscription.alive_at?(purchase_date + 9.months)).to eq true
        expect(subscription.alive_at?(purchase_date + 15.months)).to eq false
      end
    end
  end

  describe "#enable_flat_fee" do
    it "sets flat_fee_applicable to true by default" do
      expect_any_instance_of(Subscription).to receive(:enable_flat_fee).and_call_original
      expect(create(:subscription).flat_fee_applicable).to eq true
    end
  end

  describe "#discount_applies_to_next_charge?" do
    let(:user) { create(:user) }
    let(:product) { create(:membership_product_with_preset_tiered_pricing, user:) }
    let(:offer_code) { create(:offer_code, products: [product]) }
    let(:subscription) { create(:membership_purchase, link: product, offer_code:, variant_attributes: [product.alive_variants.first], price_cents: 200).subscription }

    context "when the subscription has an offer code" do
      before do
        subscription.original_purchase.create_purchase_offer_code_discount!(offer_code:, offer_code_amount: 100, offer_code_is_percent: false, pre_discount_minimum_price_cents: 300, duration_in_billing_cycles: 1)
      end

      context "when the offer code is expired" do
        it "returns false" do
          expect(subscription.discount_applies_to_next_charge?).to eq(false)
        end
      end

      context "when the offer code is not expired" do
        before do
          subscription.original_purchase.purchase_offer_code_discount.update!(duration_in_billing_cycles: 2)
        end

        it "returns true" do
          expect(subscription.discount_applies_to_next_charge?).to eq(true)
        end
      end
    end

    context "installment plans" do
      let!(:product) { create(:product, name: "Awesome product", user: seller, price_cents: 1000) }
      let!(:installment_plan) { create(:product_installment_plan, link: product, number_of_installments: 3) }
      let!(:subscription) { create(:subscription, link: product, is_installment_plan: true) }
      let!(:offer_code) { create(:offer_code, products: [product], amount_cents: 100, duration_in_billing_cycles: 1) }
      let!(:purchase) { create(:installment_plan_purchase, subscription:, link: product, offer_code:) }

      it "returns true even if the offer code is only for one membership cycle" do
        expect(subscription.discount_applies_to_next_charge?).to eq(true)
      end
    end
  end

  describe "#cookie_key" do
    it "returns the cookie key" do
      expect(@subscription.cookie_key).to eq("subscription_#{@subscription.external_id_numeric}")
    end
  end

  describe "#emails" do
    context "when the subscription has a user" do
      it "returns a hash of relevant emails" do
        user = create(:user, email: "user@email.com")
        subscription = create(:subscription, user: user)
        create(:membership_purchase, subscription:, email: "purchase@email.com")

        expect(subscription.emails).to eq({
                                            subscription: "user@email.com",
                                            purchase: "purchase@email.com",
                                            user: "user@email.com",
                                          })
      end
    end

    context "when the subscription doesn't have a user" do
      it "returns a hash of relevant emails" do
        subscription = create(:subscription, user: nil)
        create(:membership_purchase, subscription:, email: "purchase@email.com")

        expect(subscription.emails).to eq({
                                            subscription: "purchase@email.com",
                                            purchase: "purchase@email.com",
                                            user: nil,
                                          })
      end
    end

    context "when the subscription is a gift" do
      let(:subscription) { create(:subscription, user: nil) }
      let(:gift) { create(:gift, giftee_email: "giftee@email.com") }
      let!(:purchase) { create(:membership_purchase, subscription:, email: "purchase@email.com", gift_given: gift, is_gift_sender_purchase: true) }

      it "returns giftee email as purchase and subscription emails" do
        expect(subscription.emails).to eq({
                                            subscription: "giftee@email.com",
                                            purchase: "giftee@email.com",
                                            user: nil,
                                          })
      end
    end
  end

  describe "#email" do
    let(:subscription) { create(:subscription) }
    let!(:purchase) { create(:membership_purchase, subscription:, email: "purchase@example.com") }

    before do
      allow(subscription).to receive(:original_purchase).and_return(purchase)
    end

    context "when user is present" do
      it "returns user's form_email" do
        expect(subscription.email).to eq(subscription.user.form_email)
      end
    end

    context "when user is not present" do
      before do
        subscription.update!(user: nil)
      end

      it "returns purchase email" do
        expect(subscription.email).to eq(purchase.email)
      end

      context "when the subscription is a gift" do
        let(:gift) { create(:gift, giftee_email: "giftee@email.com") }

        before do
          subscription.true_original_purchase.update!(is_gift_sender_purchase: true, gift_given: gift)
        end

        it "returns giftee email" do
          expect(subscription.email).to eq(gift.giftee_email)
        end
      end
    end
  end

  describe "#refresh_token" do
    let(:subscription) { create(:subscription, token: nil, token_expires_at: nil) }

    it "sets a new token and expiration date" do
      subscription.refresh_token
      expect(subscription.token).not_to be_nil
      expect(subscription.token_expires_at).to be_within(1.second).of(Subscription::TOKEN_VALIDITY.from_now)
    end

    it "returns the newly set token" do
      token = subscription.refresh_token
      expect(token).not_to be_nil
    end
  end

  describe "#gift?" do
    let(:product) { create(:membership_product) }
    let(:subscription) { build(:subscription, link: product) }
    let(:original_purchase) { build(:membership_purchase, link: product, variant_attributes: [product.alive_variants.first]) }

    before do
      allow(subscription).to receive(:true_original_purchase).and_return(original_purchase)
    end

    context "when the original purchase is a gift sender purchase" do
      before do
        original_purchase.is_gift_sender_purchase = true
        original_purchase.gift_given = build(:gift)
      end

      it "returns true" do
        expect(subscription.gift?).to be(true)
      end
    end

    context "when the original purchase does not have a gift" do
      it "returns false" do
        expect(subscription.gift?).to be(false)
      end
    end
  end

  describe "#grant_access_to_product?" do
    context "installment plans" do
      let(:purchase) { create(:installment_plan_purchase) }
      let(:subscription) { purchase.subscription }

      it "returns false if the subscription has failed" do
        subscription.unsubscribe_and_fail!
        expect(subscription.grant_access_to_product?).to be(false)
      end

      it "returns false if the subscription is pending cancellation" do
        freeze_time

        subscription.cancel!(by_seller: true)

        expect(subscription.cancelled_at).to be_future
        expect(subscription.grant_access_to_product?).to be(false)
      end

      it "returns true even when the subscription has ended" do
        expect(subscription.grant_access_to_product?).to be(true)

        subscription.end_subscription!
        expect(subscription.grant_access_to_product?).to be(true)
      end
    end

    context "memberships" do
      let(:purchase) { create(:membership_purchase) }
      let(:subscription) { purchase.subscription }

      it "blocks access when cancelled if configured" do
        subscription.link.update!(block_access_after_membership_cancellation: false)

        subscription.cancel!
        expect(subscription.grant_access_to_product?).to be(true)

        subscription.link.update!(block_access_after_membership_cancellation: true)
        expect(subscription.grant_access_to_product?).to be(true)

        subscription.cancel_immediately_if_pending_cancellation!
        expect(subscription.grant_access_to_product?).to be(false)
      end

      it "blocks access when failed if configured" do
        subscription.link.update!(block_access_after_membership_cancellation: false)

        subscription.unsubscribe_and_fail!
        expect(subscription.grant_access_to_product?).to be(true)

        subscription.link.update!(block_access_after_membership_cancellation: true)
        expect(subscription.grant_access_to_product?).to be(false)
      end

      it "blocks access when ended if configured" do
        subscription.link.update!(block_access_after_membership_cancellation: false)

        subscription.end_subscription!
        expect(subscription.grant_access_to_product?).to be(true)

        subscription.link.update!(block_access_after_membership_cancellation: true)
        expect(subscription.grant_access_to_product?).to be(false)
      end
    end
  end
end
