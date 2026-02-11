# frozen_string_literal: true

require "spec_helper"

describe "Refund with backup card", :vcr, type: :model do
  let(:seller) { create(:user) }
  let(:buyer) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let(:credit_card) { create(:credit_card, user: seller) }
  let(:purchase) do
    create(:purchase_in_progress,
           link: product,
           seller:,
           purchaser: buyer,
           price_cents: 2000,
           total_transaction_cents: 2000).tap do |p|
      p.update_columns(succeeded_at: 1.day.ago, purchase_state: "successful")
    end
  end

  def build_charge_refund_mock(amount_cents)
    flow_of_funds = FlowOfFunds.new(
      issued_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: -amount_cents),
      settled_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: -amount_cents),
      gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: 0),
      merchant_account_gross_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: -amount_cents),
      merchant_account_net_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: -amount_cents)
    )
    stripe_refund = double("StripeRefund", id: "re_test_123", status: "succeeded")
    double("ChargeRefund", id: "re_test_123", flow_of_funds:, status: "succeeded", refund: stripe_refund)
  end

  let(:payment_intent_double) do
    Struct.new(:status, :id, :latest_charge, keyword_init: true).new(
      status: "succeeded",
      id: "pi_test_123",
      latest_charge: "ch_test_123"
    )
  end

  before do
    MerchantAccount.find_or_create_by!(user_id: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id)
    allow(purchase).to receive(:charged_using_gumroad_merchant_account?).and_return(true)
    create(:balance, user: seller, amount_cents: 500, merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id))
  end

  context "when seller has no backup payment method" do
    it "fails with insufficient balance error" do
      result = purchase.refund_and_save!(nil)

      expect(result).to be false
      expect(purchase.errors[:base]).to include("Your balance is insufficient to process this refund.")
    end
  end

  context "when seller has a backup payment method" do
    before do
      seller.update!(refund_funding_credit_card: credit_card)
    end

    context "when backup card charge succeeds and refund completes" do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_return(payment_intent_double)
        allow(ChargeProcessor).to receive(:refund!).and_return(build_charge_refund_mock(2000))
      end

      it "charges the backup card for the shortfall, creates a credit, and processes the refund" do
        expect {
          purchase.refund_and_save!(nil)
        }.to change { Credit.where.not(refund_funding_purchase_id: nil).count }.by(1)

        credit = Credit.find_by(refund_funding_purchase: purchase)
        expect(credit.amount_cents).to eq(1500) # 2000 - 500 = 1500 shortfall
        expect(credit.refund_funding_purchase).to eq(purchase)
        expect(credit.credit_card).to eq(credit_card)
        expect(credit.refund_funding_processor_transaction_id).to eq("ch_test_123")
        expect(credit.refund_funding_processor_payment_intent_id).to eq("pi_test_123")
      end

      it "sends a confirmation email" do
        expect {
          purchase.refund_and_save!(nil)
        }.to have_enqueued_job.on_queue("default").with("ContactingCreatorMailer", "refund_funding_charge_confirmation", "deliver_now", a_hash_including(credit_id: kind_of(Integer)))
      end
    end

    context "when shortfall is less than minimum charge" do
      before do
        create(:balance, user: seller, amount_cents: 1450, merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id))
        allow(Stripe::PaymentIntent).to receive(:create).and_return(payment_intent_double)
        allow(ChargeProcessor).to receive(:refund!).and_return(build_charge_refund_mock(2000))
      end

      it "charges the minimum amount of $1.00" do
        purchase.refund_and_save!(nil)

        credit = Credit.find_by(refund_funding_purchase: purchase)
        expect(credit.amount_cents).to eq(100)
      end
    end

    context "when backup card charge fails" do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_raise(
          Stripe::CardError.new("Card declined", nil, code: "card_declined")
        )
      end

      it "fails the refund without processing" do
        expect(ChargeProcessor).not_to receive(:refund!)
        expect { purchase.refund_and_save!(nil) }.not_to change(Credit, :count)

        expect(purchase.errors[:base].first).to include("Card declined")
      end
    end

    context "when ChargeProcessor.refund! fails after backup card charge succeeds" do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_return(payment_intent_double)
        allow(ChargeProcessor).to receive(:refund!).and_raise(
          ChargeProcessorUnavailableError.new("Stripe unavailable")
        )
      end

      it "reverses the backup card charge" do
        expect(RefundFundingChargeService).to receive(:reverse_charge!).with(payment_intent_id: "pi_test_123")

        purchase.refund_and_save!(nil)
      end
    end

    context "when balance re-check fails after backup card charge (concurrent refund)" do
      before do
        allow(Stripe::PaymentIntent).to receive(:create).and_return(payment_intent_double)
        # Simulate a concurrent refund draining the balance between charge and check
        allow(seller).to receive(:reload).and_return(seller)
        allow(seller).to receive(:unpaid_balance_cents).and_return(500, 0)
      end

      it "reverses the backup card charge and returns insufficient balance error" do
        expect(RefundFundingChargeService).to receive(:reverse_charge!).with(payment_intent_id: "pi_test_123")

        result = purchase.refund_and_save!(nil)
        expect(result).to be false
        expect(purchase.errors[:base]).to include("Your balance is insufficient to process this refund.")
      end
    end
  end
end
