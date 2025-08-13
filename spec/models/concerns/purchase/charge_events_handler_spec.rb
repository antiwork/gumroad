# frozen_string_literal: true

require "spec_helper"

describe Purchase::ChargeEventsHandler, :vcr do
  include CurrencyHelper
  include ProductsHelper

  describe "charge event looked up by external ID" do
    let(:purchase) { create(:purchase, price_cents: 100, total_transaction_cents: 100, fee_cents: 30) }
    let(:event) { build(:charge_event_dispute_formalized, charge_reference: purchase.external_id) }

    before do
      allow_any_instance_of(Purchase).to receive(:create_dispute_evidence_if_needed!).and_return(nil)
    end

    it "uses charge_reference which is expected to be the purchase external ID" do
      Purchase.handle_charge_event(event)
      purchase.reload
      expect(purchase.stripe_status).to eq(event.comment)
      expect(purchase.chargeback_date.to_i).to eq(event.created_at.to_i)
    end
  end

  describe "setting the purchase fee from a charge event" do
    before do
      @l = create(:product)
      @p = create(:purchase, link: @l, seller: @l.user, price_cents: 100,
                             total_transaction_cents: 100)
      @p.processor_fee_cents = 0
      @p.save!

      @e = build(:charge_event_informational, charge_reference: @p.external_id, extras: { "fee_cents" => 30_00 })
    end

    it "set the fee on the purchase if the information charge event has the info" do
      expect(@p.processor_fee_cents).to eq(0)

      Purchase.handle_charge_event(@e)
      @p.reload

      expect(@p.stripe_status).to eq(@e.comment)
      expect(@p.processor_fee_cents).to eq(@e.extras["fee_cents"])
    end
  end

  describe "informational charge event for purchase" do
    before do
      @initial_balance = 200
      @u = create(:user, unpaid_balance_cents: @initial_balance)
      @l = create(:product, user: @u)
      @p = create(:purchase, link: @l, seller: @l.user, stripe_transaction_id: "ch_zitkxbhds3zqlt", price_cents: 100,
                             total_transaction_cents: 100, fee_cents: 30)
      @e = build(:charge_event_informational, charge_id: "ch_zitkxbhds3zqlt")
      allow_any_instance_of(Purchase).to receive(:fight_chargeback).and_return(true)
    end

    it "does not affect seller balance" do
      Purchase.handle_charge_event(@e)
      @p.reload
      @u.reload
      verify_balance(@u, @initial_balance)
    end

    it "updates purchase current status" do
      Purchase.handle_charge_event(@e)
      @p.reload
      expect(@p.stripe_status).to eq @e.comment
    end
  end

  describe "charge succeeded event for purchase" do
    let(:initial_balance) { 200 }
    let(:seller) { create(:user, unpaid_balance_cents: initial_balance) }
    let!(:recurring_purchase) do
      create(
        :recurring_membership_purchase,
        stripe_transaction_id: "ch_2ORDpK9e1RjUNIyY0eJyh91P",
        price_cents: 100,
        total_transaction_cents: 100,
        fee_cents: 30,
        purchase_state: "in_progress",
        card_country: Compliance::Countries::IND.alpha2
      )
    end
    let(:event) { build(:charge_event_charge_succeeded, charge_id: "ch_2ORDpK9e1RjUNIyY0eJyh91P") }

    before do
      expect_any_instance_of(Purchase).to receive(:handle_event_informational!).and_call_original
      expect_any_instance_of(Purchase).to receive(:save_charge_data)
      expect_any_instance_of(Purchase).to receive(:update_balance_and_mark_successful!)
    end

    it "does not affect seller balance" do
      Purchase.handle_charge_event(event)
      recurring_purchase.reload
      seller.reload
      verify_balance(seller, initial_balance)
    end

    it "updates purchase current status" do
      Purchase.handle_charge_event(event)
      recurring_purchase.reload
      expect(recurring_purchase.stripe_status).to eq event.comment
    end
  end

  describe "payment failed event for purchase" do
    before do
      @initial_balance = 200
      @u = create(:user, unpaid_balance_cents: @initial_balance)
      @l = create(:product, user: @u)
      subscription = create(:subscription)
      create(:membership_purchase, subscription:)
      purchase_external_id = "q3jUBQrrGrIId3SjC4VJ0g=="
      @p = create(:purchase, id: ObfuscateIds.decrypt(purchase_external_id), link: @l, seller: @l.user, price_cents: 100,
                             total_transaction_cents: 100, fee_cents: 30, purchase_state: "in_progress", card_country: "IN",
                             subscription:)
      @e = build(:charge_event_payment_failed, charge_reference: purchase_external_id)

      allow(Purchase).to receive(:find_by_external_id).with(purchase_external_id).and_return(@p)
      expect_any_instance_of(Purchase).to receive(:handle_event_informational!).and_call_original
      expect_any_instance_of(Subscription).to receive(:handle_purchase_failure)
    end

    it "does not affect seller balance" do
      Purchase.handle_charge_event(@e)
      @p.reload
      @u.reload
      verify_balance(@u, @initial_balance)
    end

    it "updates purchase current status" do
      Purchase.handle_charge_event(@e)
      @p.reload
      expect(@p.stripe_status).to eq @e.comment
    end

    it "finds the purchase using processor_payment_intent and marks it as failed" do
      processor_payment_intent_id = "pi_123456"
      @p.create_processor_payment_intent!(intent_id: processor_payment_intent_id)

      event = build(:charge_event_payment_failed, charge_id: nil, processor_payment_intent_id:)
      expect(event.charge_reference).to be nil
      expect(event.charge_id).to be nil
      expect(event.processor_payment_intent_id).to eq processor_payment_intent_id
      expect_any_instance_of(Purchase).to receive(:handle_event_failed!).and_call_original

      Purchase.handle_charge_event(event)
    end
  end

  describe "handles charge event notification" do
    let(:charge_event) { build(:charge_event_informational) }

    it "calls purchase's handle_charge_event" do
      expect(Purchase).to receive(:handle_charge_event).with(charge_event).once
      expect(ServiceCharge).to_not receive(:handle_charge_processor_event)
      ActiveSupport::Notifications.instrument(ChargeProcessor::NOTIFICATION_CHARGE_EVENT, charge_event:)
    end
  end

  describe "#handle charge event" do
    let(:transaction_id) { "ch_zitkxbhds3zqlt" }
    let(:initial_balance) { 10_000 }
    let(:seller) { create(:user, unpaid_balance_cents: initial_balance) }
    let(:product) { create(:product, user: seller) }
    let(:balance) { seller.balances.reload.last }
    let(:purchase) { create(:purchase, stripe_transaction_id: transaction_id, link: product) }
    let!(:purchase_event) { create(:event, event_name: "purchase", purchase_id: purchase.id, link_id: product.id) }
    let(:calculated_fingerprint) { "3dfakl93klfdjsa09rn" }

    it "handles stripe events correctly - type informational" do
      charge_event = build(:charge_event, charge_id: transaction_id, comment: "charge.succeeded")

      Purchase.handle_charge_event(charge_event)

      purchase.reload
      expect(purchase.stripe_status).to eq "charge.succeeded"
    end

    it "sets the purchase chargeback_date flag and email us" do
      charge_event = build(:charge_event_dispute_formalized, charge_id: transaction_id)
      mail = double("mail")
      expect(mail).to receive(:deliver_later)
      allow(AdminMailer).to receive(:chargeback_notify).and_return(mail)

      Purchase.handle_charge_event(charge_event)
      expect(FightDisputeJob).to have_enqueued_sidekiq_job(purchase.dispute.id)
      expect(AdminMailer).to have_received(:chargeback_notify).with(purchase.dispute.id)

      purchase.reload
      seller.reload
      verify_balance(seller, initial_balance - purchase.payment_cents)
      expect(purchase.purchase_chargeback_balance).to eq balance
      expect(purchase.chargeback_date.to_i).to eq charge_event.created_at.to_i
      expect(Event.last.event_name).to eq "chargeback"
      expect(Event.last.purchase_id).to eq purchase.id
    end

    it "enqueues LowBalanceFraudCheckWorker" do
      charge_event = build(:charge_event_dispute_formalized, charge_id: transaction_id)
      Purchase.handle_charge_event(charge_event)

      expect(FightDisputeJob).to have_enqueued_sidekiq_job(purchase.dispute.id)
      expect(LowBalanceFraudCheckWorker).to have_enqueued_sidekiq_job(purchase.id)
    end

    it "enqueues UpdateSalesRelatedProductsInfosJob" do
      UpdateSalesRelatedProductsInfosJob.jobs.clear
      Purchase.handle_charge_event(build(:charge_event_dispute_formalized, charge_id: transaction_id))

      expect(FightDisputeJob).to have_enqueued_sidekiq_job(purchase.dispute.id)
      expect(UpdateSalesRelatedProductsInfosJob).to have_enqueued_sidekiq_job(purchase.id, false)
    end

    it "updates dispute evidence as seller contacted" do
      charge_event = build(:charge_event_dispute_formalized, charge_id: transaction_id)
      Purchase.handle_charge_event(charge_event)

      expect(purchase.dispute.dispute_evidence.seller_contacted?).to eq(true)
    end

    context "when the purchase is not eligible for a dispute evidence" do
      before do
        allow_any_instance_of(Purchase).to receive(:eligible_for_dispute_evidence?).and_return(false)
      end

      it "doesn't enqueue FightDisputeJob job" do
        charge_event = build(:charge_event_dispute_formalized, charge_id: transaction_id)
        Purchase.handle_charge_event(charge_event)
        expect(FightDisputeJob).not_to have_enqueued_sidekiq_job(purchase.dispute.id)
      end
    end

    context "when a chargeback is reversed" do
      it "enqueues UpdateSalesRelatedProductsInfosJob" do
        purchase.update!(chargeback_date: 1.day.ago)
        UpdateSalesRelatedProductsInfosJob.jobs.clear
        Purchase.handle_charge_event(build(:charge_event_dispute_won, charge_id: transaction_id))

        expect(UpdateSalesRelatedProductsInfosJob).to have_enqueued_sidekiq_job(purchase.id, true)
      end
    end

    it "handles dispute formalized event properly for partially refunded purchase" do
      partially_refunded_cents = 50
      create(:refund, purchase:, amount_cents: 50, fee_cents: 15)
      purchase.stripe_partially_refunded = true
      purchase.save!
      amount_refundable_cents = purchase.amount_refundable_cents
      expect(amount_refundable_cents).to eq(purchase.price_cents - partially_refunded_cents)

      charge_event = build(:charge_event_dispute_formalized, charge_id: transaction_id)
      mail = double("mail")
      expect(mail).to receive(:deliver_later)
      expect(AdminMailer).to receive(:chargeback_notify).and_return(mail)
      Purchase.handle_charge_event(charge_event) # This will decrement 31c from seller balance
      purchase.reload
      seller.reload
      verify_balance(seller, initial_balance - (amount_refundable_cents * (1 - (purchase.fee_cents.to_f / purchase.price_cents.to_f))).ceil) # 10000 - (50 * (1 - (39 / 100))) = 9969
      expect(purchase.purchase_chargeback_balance).to eq balance
      expect(purchase.chargeback_date.to_i).to eq charge_event.created_at.to_i
      expect(Event.last.event_name).to eq "chargeback"
      expect(Event.last.purchase_id).to eq purchase.id
    end

    describe "dispute formalized event for free trial subscriptions" do
      let(:charge_event) { build(:charge_event_dispute_formalized, charge_id: transaction_id) }
      let(:original_purchase) { create(:free_trial_membership_purchase, price_cents: 100, should_exclude_product_review: false) }
      let(:subscription) { original_purchase.subscription }
      let!(:purchase) do create(:purchase, stripe_transaction_id: transaction_id, subscription:,
                                           link: original_purchase.link, price_cents: 100, chargeback_date: Date.today - 10.days,
                                           url_redirect: create(:url_redirect)) end

      before do
        allow_any_instance_of(Purchase).to receive(:create_dispute_evidence_if_needed!).and_return(nil)
      end

      it "prevents the subscriber's review from being counted" do
        expect do
          Purchase.handle_charge_event(charge_event)
        end.to change { original_purchase.reload.should_exclude_product_review? }.from(false).to(true)
      end
    end

    # Can happen due to charge processor (Braintree) bugs
    describe "chargeback events for unsuccessful purchases" do
      let!(:purchase) do
        p = create(:purchase_with_balance)
        p.update!(purchase_state: "failed")
        p
      end

      describe "chargeback notification received" do
        it "does not process the message" do
          expect(purchase).to_not receive(:process_refund_or_chargeback_for_purchase_balance)
          expect(purchase).to_not receive(:process_refund_or_chargeback_for_affiliate_credit_balance)
          expect(Bugsnag).to receive(:notify)

          Purchase.handle_charge_event(build(:charge_event_dispute_formalized, charge_id: purchase.stripe_transaction_id))
        end
      end

      describe "chargeback reversed notification received" do
        it "does not process the message" do
          expect(Credit).to_not receive(:create)
          expect(Bugsnag).to receive(:notify)

          Purchase.handle_charge_event(build(:charge_event_dispute_won, charge_id: purchase.stripe_transaction_id))
        end
      end
    end

    describe "refunded purchase" do
      it "enqueues UpdateSalesRelatedProductsInfosJob" do
        purchase.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 100), purchase.seller_id)

        expect(UpdateSalesRelatedProductsInfosJob).to have_enqueued_sidekiq_job(purchase.id, true)
      end
    end

    describe "settlement declined event" do
      let(:settlement_decline_flow_of_funds) { FlowOfFunds.build_simple_flow_of_funds(Currency::USD, -100) }

      describe "for a unsuccessful purchase" do
        before do
          purchase.purchase_state = "failed"
          purchase.save!
        end

        it "notifies bugsnag" do
          expect(Bugsnag).to receive(:notify)
          Purchase.handle_charge_event(build(:charge_event_dispute_formalized, charge_id: purchase.stripe_transaction_id))
        end
      end

      describe "for a successful purchase" do
        it "marks the purchased as refunded, updates balances" do
          expect_any_instance_of(Purchase).to receive(:refund_purchase!).and_call_original
          expect_any_instance_of(Purchase).to receive(:process_refund_or_chargeback_for_purchase_balance)
          expect_any_instance_of(Purchase).to receive(:process_refund_or_chargeback_for_affiliate_credit_balance)
          expect_any_instance_of(Bugsnag).to_not receive(:notify)

          Purchase.handle_charge_event(build(:charge_event_settlement_declined, charge_id: purchase.stripe_transaction_id, flow_of_funds: settlement_decline_flow_of_funds))
        end
      end
    end
  end

  def verify_balance(user, expected_balance)
    expect(user.unpaid_balance_cents).to eq expected_balance
  end
end
