# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillStripePaymentMethodTypes do
  def create_upi_shaped_purchase(card_type: nil, created_at: Time.utc(2026, 7, 23, 12), stripe_transaction_id: "ch_upi_#{SecureRandom.hex(6)}")
    purchase = create(:purchase, stripe_transaction_id:, created_at:)
    # The factory always sets a card brand; recreate the pre-fix UPI shape directly.
    purchase.update_columns(card_type:, card_visual: nil)
    purchase
  end

  def stub_charge(transaction_id, method_type)
    allow(ChargeProcessor).to receive(:get_charge)
      .with(StripeChargeProcessor.charge_processor_id, transaction_id, merchant_account: anything)
      .and_return(double(payment_method_type: method_type))
  end

  describe ".process" do
    it "backfills card_type and the payment-flow row for a UPI purchase recorded with nil card_type" do
      purchase = create_upi_shaped_purchase
      flow = create(:purchase_payment_flow, purchase:)
      stub_charge(purchase.stripe_transaction_id, "upi")

      stats = described_class.process(dry_run: false)

      expect(purchase.reload.card_type).to eq(CardType::UPI)
      expect(flow.reload.stripe_payment_method_type).to eq("upi")
      expect(stats[:fixed_card_type]).to eq(1)
      expect(stats[:fixed_flow]).to eq(1)
    end

    it "backfills a client-confirm purchase recorded as generic_card" do
      purchase = create_upi_shaped_purchase(card_type: CardType::UNKNOWN)
      stub_charge(purchase.stripe_transaction_id, "upi")

      described_class.process(dry_run: false)

      expect(purchase.reload.card_type).to eq(CardType::UPI)
    end

    it "leaves a candidate alone when Stripe classifies it as a plain card" do
      purchase = create_upi_shaped_purchase
      flow = create(:purchase_payment_flow, purchase:)
      stub_charge(purchase.stripe_transaction_id, "card")

      stats = described_class.process(dry_run: false)

      expect(purchase.reload.card_type).to be_nil
      expect(flow.reload.stripe_payment_method_type).to eq("card")
      expect(stats[:skipped_not_local_method]).to eq(1)
    end

    it "does not collapse an unrecognized method into generic_card" do
      purchase = create_upi_shaped_purchase
      stub_charge(purchase.stripe_transaction_id, "paynow")

      stats = described_class.process(dry_run: false)

      expect(purchase.reload.card_type).to be_nil
      expect(stats[:skipped_not_local_method]).to eq(1)
    end

    it "skips purchases whose charge reports no method type" do
      purchase = create_upi_shaped_purchase
      stub_charge(purchase.stripe_transaction_id, nil)

      stats = described_class.process(dry_run: false)

      expect(purchase.reload.card_type).to be_nil
      expect(stats[:skipped_no_method_type]).to eq(1)
    end

    it "still fixes card_type when the purchase has no payment-flow row" do
      purchase = create_upi_shaped_purchase
      stub_charge(purchase.stripe_transaction_id, "upi")

      stats = described_class.process(dry_run: false)

      expect(purchase.reload.card_type).to eq(CardType::UPI)
      expect(stats[:no_payment_flow_row]).to eq(1)
    end

    it "writes nothing on a dry run" do
      purchase = create_upi_shaped_purchase
      flow = create(:purchase_payment_flow, purchase:)
      stub_charge(purchase.stripe_transaction_id, "upi")

      stats = described_class.process

      expect(purchase.reload.card_type).to be_nil
      expect(flow.reload.stripe_payment_method_type).to eq("card")
      expect(stats[:would_fix_card_type]).to eq(1)
      expect(stats[:would_fix_flow]).to eq(1)
      expect(stats[:dry_run]).to eq(true)
    end

    it "is idempotent: a second run skips already-corrected rows without refetching writes" do
      purchase = create_upi_shaped_purchase(card_type: CardType::UNKNOWN)
      flow = create(:purchase_payment_flow, purchase:)
      stub_charge(purchase.stripe_transaction_id, "upi")

      described_class.process(dry_run: false)
      # After the first run card_type is "upi", so the purchase is no longer a candidate.
      stats = described_class.process(dry_run: false)

      expect(purchase.reload.card_type).to eq(CardType::UPI)
      expect(flow.reload.stripe_payment_method_type).to eq("upi")
      expect(stats[:fixed_card_type]).to be_nil.or eq(0)
    end

    it "fetches a shared combined charge once for multiple purchases on the same transaction" do
      shared_id = "ch_combined_#{SecureRandom.hex(6)}"
      purchase_one = create_upi_shaped_purchase(stripe_transaction_id: shared_id)
      purchase_two = create_upi_shaped_purchase(stripe_transaction_id: shared_id)
      charge = double(payment_method_type: "upi")
      expect(ChargeProcessor).to receive(:get_charge)
        .with(StripeChargeProcessor.charge_processor_id, shared_id, merchant_account: anything)
        .once
        .and_return(charge)

      described_class.process(dry_run: false)

      expect(purchase_one.reload.card_type).to eq(CardType::UPI)
      expect(purchase_two.reload.card_type).to eq(CardType::UPI)
    end

    it "rolls back the card_type write when the payment-flow update fails, so a rerun can retry" do
      purchase = create_upi_shaped_purchase
      flow = create(:purchase_payment_flow, purchase:)
      stub_charge(purchase.stripe_transaction_id, "upi")
      allow_any_instance_of(PurchasePaymentFlow).to receive(:update!)
        .and_raise(ActiveRecord::RecordInvalid)

      stats = described_class.process(dry_run: false)

      expect(stats[:errors]).to eq(1)
      # The rolled-back card_type write must not be counted as fixed — stats only
      # count writes whose transaction committed.
      expect(stats[:fixed_card_type]).to eq(0)
      expect(stats[:fixed_flow]).to eq(0)
      # card_type must roll back too — otherwise the purchase drops out of the candidate
      # scope and the flow row stays stuck at "card" forever.
      expect(purchase.reload.card_type).to be_nil
      expect(flow.reload.stripe_payment_method_type).to eq("card")

      # A rerun with the failure gone repairs both rows.
      allow_any_instance_of(PurchasePaymentFlow).to receive(:update!).and_call_original
      described_class.process(dry_run: false)
      expect(purchase.reload.card_type).to eq(CardType::UPI)
      expect(flow.reload.stripe_payment_method_type).to eq("upi")
    end

    it "records an error and keeps going when a charge fetch raises" do
      failing = create_upi_shaped_purchase
      healthy = create_upi_shaped_purchase
      allow(ChargeProcessor).to receive(:get_charge)
        .with(StripeChargeProcessor.charge_processor_id, failing.stripe_transaction_id, merchant_account: anything)
        .and_raise(ChargeProcessorError.new("boom"))
      stub_charge(healthy.stripe_transaction_id, "upi")

      stats = described_class.process(dry_run: false)

      expect(stats[:errors]).to eq(1)
      expect(healthy.reload.card_type).to eq(CardType::UPI)
    end

    it "does not select purchases outside the window, non-Stripe purchases, or ones with a recorded card brand" do
      create_upi_shaped_purchase(created_at: Time.utc(2026, 7, 20)) # before UPI launch
      create(:purchase, card_type: "visa", created_at: Time.utc(2026, 7, 23, 12)) # correctly recorded card
      paypal = create(:purchase, charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                                 stripe_transaction_id: "pp_txn", created_at: Time.utc(2026, 7, 23, 12))
      paypal.update_columns(card_type: nil)
      expect(ChargeProcessor).not_to receive(:get_charge)

      stats = described_class.process(dry_run: false, to: Time.utc(2026, 7, 24))

      expect(stats.except(:dry_run).values.sum).to eq(0)
    end
  end
end
