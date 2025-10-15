# frozen_string_literal: true

require "rails_helper"

RSpec.describe RefundBalanceTopUpService do
  let(:user) { create(:user, unpaid_balance_cents: 0) }
  let!(:merchant_account) do
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      MerchantAccount.create!(charge_processor_id: StripeChargeProcessor.charge_processor_id)
  end
  let(:credit_card) do
    CreditCard.create!(
      stripe_fingerprint: "fp_test",
      visual: "**** **** **** 4242",
      card_type: CardType::VISA,
      stripe_customer_id: "cus_test",
      expiry_month: 4,
      expiry_year: 2030,
      charge_processor_id: StripeChargeProcessor.charge_processor_id
    )
  end
  let!(:refund_payment_method) { RefundPaymentMethod.create!(user:, credit_card:, cardholder_name: "Creator Name") }
  let(:product) { create(:product, user:) }
  let(:purchase) { create(:purchase, link: product, price_cents: 2_500) }
  let(:service) { described_class.new(user:, purchase:, required_cents: 1_000) }
  let(:chargeable_double) { double("chargeable") }
  let(:flow_of_funds) { FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 1_200) }
  let(:charge_double) do
    instance_double(StripeCharge,
                    flow_of_funds:,
                    charge_processor_id: StripeChargeProcessor.charge_processor_id,
                    id: "ch_test")
  end
  let(:successful_charge_intent) do
    instance_double(StripeChargeIntent,
                    succeeded?: true,
                    requires_action?: false,
                    charge: charge_double)
  end

  before do
    allow(credit_card).to receive(:to_chargeable).and_return(chargeable_double)
    allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!).and_return(successful_charge_intent)
  end

  it "charges the backup card and credits the seller balance" do
    result = service.ensure_funds

    expect(result.success?).to be(true)
    expect(user.reload.unpaid_balance_cents).to eq(flow_of_funds.gumroad_amount.cents)

    credit = user.credits.order(id: :desc).first
    expect(credit.amount_cents).to eq(flow_of_funds.gumroad_amount.cents)
    expect(credit.json_data["refund_balance_top_up"]).to include(
      "charge_id" => "ch_test",
      "charge_processor_id" => StripeChargeProcessor.charge_processor_id,
    )

    expect(ChargeProcessor).to have_received(:create_payment_intent_or_charge!).with(
      merchant_account,
      chargeable_double,
      kind_of(Integer),
      kind_of(Integer),
      purchase.external_id,
      "Refund coverage top-up for purchase #{purchase.external_id}",
      hash_including(metadata: hash_including(:purchase_id, :seller_id, :context)),
      hash_including(off_session: true)
    )
  end

  it "returns an error when the backup method requires additional authentication" do
    allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!).and_return(
      instance_double(StripeChargeIntent, succeeded?: false, requires_action?: true, charge: nil)
    )

    result = service.ensure_funds

    expect(result.success?).to be(false)
    expect(result.error_message).to include("authentication")
  end

  it "does nothing when there is no deficit to cover" do
    user.update!(unpaid_balance_cents: 5_000)

    result = service.ensure_funds

    expect(result.success?).to be(true)
    expect(ChargeProcessor).not_to have_received(:create_payment_intent_or_charge!)
  end

  it "attempts to charge multiple times until the deficit is cleared" do
    first_flow = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 400)
    second_flow = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 700)
    first_charge = instance_double(StripeCharge,
                                   flow_of_funds: first_flow,
                                   charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                   id: "ch_partial")
    second_charge = instance_double(StripeCharge,
                                    flow_of_funds: second_flow,
                                    charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                    id: "ch_final")
    first_intent = instance_double(StripeChargeIntent,
                                   succeeded?: true,
                                   requires_action?: false,
                                   charge: first_charge)
    second_intent = instance_double(StripeChargeIntent,
                                    succeeded?: true,
                                    requires_action?: false,
                                    charge: second_charge)
    allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!)
      .and_return(first_intent, second_intent)

    result = service.ensure_funds

    expect(result.success?).to be(true)
    expect(ChargeProcessor).to have_received(:create_payment_intent_or_charge!).twice
    expect(user.reload.unpaid_balance_cents).to eq(first_flow.gumroad_amount.cents + second_flow.gumroad_amount.cents)
  end

  it "stops after max attempts when the deficit cannot be covered" do
    small_flow = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 100)
    charge = instance_double(StripeCharge,
                             flow_of_funds: small_flow,
                             charge_processor_id: StripeChargeProcessor.charge_processor_id,
                             id: "ch_small")
    intent = instance_double(StripeChargeIntent,
                             succeeded?: true,
                             requires_action?: false,
                             charge:)
    allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!).and_return(intent)

    result = service.ensure_funds

    expect(result.success?).to be(false)
    expect(result.error_message).to include("couldn't add enough funds")
    expect(ChargeProcessor).to have_received(:create_payment_intent_or_charge!).exactly(described_class::MAX_ATTEMPTS).times
  end

  it "surfaces processor card errors" do
    allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!)
      .and_raise(ChargeProcessorCardError.new("Declined", nil))

    result = service.ensure_funds

    expect(result.success?).to be(false)
    expect(result.error_message).to include("Declined")
  end

  it "returns an error when no refund payment method exists" do
    refund_payment_method.destroy!

    result = service.ensure_funds

    expect(result.success?).to be(false)
    expect(result.error_message).to include("backup payment method")
  end
end
