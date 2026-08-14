# frozen_string_literal: true

require "spec_helper"

describe "Indian card mandate reliability" do
  let(:seller) { create(:user) }
  let(:product) { create(:subscription_product, user: seller) }
  let(:buyer) { create(:user) }
  let(:card) do
    CreditCard.create!(
      charge_processor_id: StripeChargeProcessor.charge_processor_id,
      stripe_customer_id: "cus_shared",
      processor_payment_method_id: "pm_shared",
      stripe_fingerprint: "fingerprint_shared",
      visual: "**** **** **** 4242",
      card_type: CardType::VISA,
      card_country: Compliance::Countries::IND.alpha2,
      expiry_month: 12,
      expiry_year: 2030
    )
  end
  let(:merchant_account) do
    create(
      :merchant_account,
      user: nil,
      charge_processor_id: StripeChargeProcessor.charge_processor_id,
      charge_processor_merchant_id: nil
    )
  end

  before do
    allow(MerchantAccount).to receive(:gumroad)
      .with(StripeChargeProcessor.charge_processor_id)
      .and_return(merchant_account)
    Feature.activate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)
  end

  after do
    Feature.deactivate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)
  end

  def create_registration
    purchase = create(
      :membership_purchase,
      link: product,
      seller:,
      purchaser: buyer,
      credit_card: card,
      merchant_account:,
      stripe_transaction_id: "ch_registration"
    )
    purchase.subscription.update!(user: buyer, credit_card: card)
    purchase
  end

  it "keeps enforcement off when the feature is off" do
    Feature.deactivate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)
    registration = create_registration

    expect(registration.india_card_mandate_reliability_enabled?).to be(false)
    expect(registration.subscription.india_card_mandate_reliability_enabled?).to be(false)
  end

  it "does not validate mandates for non-Stripe rebills" do
    renewal = build(
      :purchase,
      link: product,
      seller:,
      purchaser: buyer,
      credit_card: card,
      charge_processor_id: BraintreeChargeProcessor.charge_processor_id,
      stripe_transaction_id: nil,
      merchant_account: nil
    )

    expect do
      renewal.send(:validate_indian_card_mandate_for_rebill!, instance_double(Chargeable))
    end.not_to raise_error
  end

  it "does not apply subscription mandate validation to preorder releases" do
    release = build(
      :purchase,
      link: product,
      seller:,
      purchaser: buyer,
      credit_card: card,
      merchant_account:,
      stripe_transaction_id: nil,
      charge_processor_id: StripeChargeProcessor.charge_processor_id
    )
    allow(release).to receive(:preorder).and_return(instance_double(Preorder))

    expect do
      release.send(:validate_indian_card_mandate_for_rebill!, instance_double(Chargeable))
    end.not_to raise_error
  end

  it "does not enforce mandates for direct Connect charges" do
    direct_account = create(:merchant_account_stripe_connect, user: seller)
    registration = create(
      :membership_purchase,
      link: product,
      seller:,
      purchaser: buyer,
      credit_card: card,
      merchant_account: direct_account,
      stripe_transaction_id: "ch_registration"
    )

    expect(registration.india_card_mandate_reliability_enabled?).to be(false)
    expect(registration.subscription.india_card_mandate_reliability_enabled?).to be(true)
  end

  it "does not enforce mandates when the seller's current route is direct Connect" do
    registration = create_registration
    create(:merchant_account_stripe_connect, user: seller)
    seller.update!(check_merchant_account_is_linked: true)

    expect(registration.subscription.reload.india_card_mandate_reliability_enabled?).to be(false)
  end

  it "does not use a source from an old direct Connect route" do
    direct_account = create(:merchant_account_stripe_connect, user: seller)
    seller.update!(check_merchant_account_is_linked: false)
    registration = create(
      :membership_purchase,
      link: product,
      seller:,
      purchaser: buyer,
      credit_card: card,
      merchant_account: direct_account,
      stripe_transaction_id: "ch_registration"
    )
    registration.subscription.update!(user: buyer, credit_card: card)

    expect(registration.subscription.reload.india_card_mandate_reliability_enabled?).to be(true)
    expect(registration.subscription.indian_card_mandate_for(card.id)).to eq([nil, "missing", nil])
  end

  it "uses the registration purchase instead of a later shared-card pointer" do
    registration = create_registration
    subscription = registration.subscription
    registration.mark_indian_card_mandate_registration!
    create(
      :purchase,
      link: product,
      seller:,
      purchaser: buyer,
      subscription:,
      credit_card: card,
      merchant_account:,
      stripe_transaction_id: "ch_later"
    )
    card.update!(json_data: { stripe_payment_intent_id: "pi_other_subscription" })

    expect(subscription.indian_card_mandate_source_purchase(card.id)).to eq(registration)
  end

  it "binds an active mandate from the subscription purchase to the renewal" do
    registration = create_registration
    subscription = registration.subscription
    registration.mark_indian_card_mandate_registration!
    renewal = build(
      :purchase,
      link: product,
      seller:,
      purchaser: buyer,
      subscription:,
      credit_card: card,
      merchant_account:
    )
    mandate = Stripe::Mandate.construct_from(id: "mandate_subscription", status: "active", payment_method: "pm_shared")
    allow(subscription).to receive(:indian_card_mandate_source_purchase).with(card.id).and_return(registration)
    allow(registration).to receive(:retrieve_indian_card_mandate).and_return([mandate, "active"])
    allow(registration).to receive(:record_indian_card_mandate_status!).with("active", mandate_id: "mandate_subscription")
    stripe_chargeable = instance_double(StripeChargeableCreditCard)
    expect(stripe_chargeable).to receive(:validated_stripe_mandate_id=).with("mandate_subscription")
    chargeable = instance_double(Chargeable)
    allow(chargeable).to receive(:get_chargeable_for).with(StripeChargeProcessor.charge_processor_id).and_return(stripe_chargeable)

    renewal.send(:validate_indian_card_mandate_for_rebill!, chargeable)
  end

  it "rejects an inactive mandate before the renewal reaches Stripe" do
    registration = create_registration
    subscription = registration.subscription
    registration.mark_indian_card_mandate_registration!
    renewal = build(
      :purchase,
      link: product,
      seller:,
      purchaser: buyer,
      subscription:,
      credit_card: card,
      merchant_account:
    )
    allow(subscription).to receive(:indian_card_mandate_source_purchase).with(card.id).and_return(registration)
    allow(registration).to receive(:retrieve_indian_card_mandate).and_return([nil, "inactive"])
    allow(registration).to receive(:record_indian_card_mandate_status!).with("inactive", mandate_id: nil)
    allow(ErrorNotifier).to receive(:notify)

    expect do
      renewal.send(:validate_indian_card_mandate_for_rebill!, instance_double(Chargeable))
    end.to raise_error(ChargeProcessorCardError) do |error|
      expect(error.error_code).to eq(PurchaseErrorCode::INDIA_CARD_MANDATE_INACTIVE)
    end
  end

  it "starts checks for a pending source created before the feature rollout" do
    registration = create_registration
    subscription = registration.subscription
    renewal = build(
      :purchase,
      link: product,
      seller:,
      purchaser: buyer,
      subscription:,
      credit_card: card,
      merchant_account:
    )
    allow(subscription).to receive(:indian_card_mandate_for).with(card.id).and_return([nil, "pending", registration])
    allow(registration).to receive(:record_indian_card_mandate_status!).with("pending", mandate_id: nil)
    expect(registration).to receive(:mark_indian_card_mandate_registration!)
    expect(CheckIndianCardMandateRegistrationJob).to receive(:perform_async).with(registration.id)
    allow(ErrorNotifier).to receive(:notify)

    expect do
      renewal.send(:validate_indian_card_mandate_for_rebill!, instance_double(Chargeable))
    end.to raise_error(ChargeProcessorCardError) do |error|
      expect(error.error_code).to eq(PurchaseErrorCode::INDIA_CARD_MANDATE_PENDING)
    end
  end

  it "does not use the shared card pointer when the subscription has no exact source" do
    subscription = create(:subscription, link: product, user: buyer, credit_card: card)
    source = create(
      :membership_purchase,
      link: product,
      seller:,
      purchaser: buyer,
      subscription:,
      credit_card: card,
      merchant_account:,
      stripe_transaction_id: "ch_removed"
    )
    source.update_columns(stripe_transaction_id: nil, processor_setup_intent_id: nil)
    card.update!(json_data: { stripe_payment_intent_id: "pi_other_subscription" })
    renewal = build(
      :purchase,
      link: product,
      seller:,
      purchaser: buyer,
      subscription:,
      credit_card: card,
      merchant_account:
    )
    allow(ErrorNotifier).to receive(:notify)

    expect(ChargeProcessor).not_to receive(:get_charge_intent)
    expect do
      renewal.send(:validate_indian_card_mandate_for_rebill!, instance_double(Chargeable))
    end.to raise_error(ChargeProcessorCardError) do |error|
      expect(error.error_code).to eq(PurchaseErrorCode::INDIA_CARD_MANDATE_MISSING)
    end
  end

  it "uses the mandate stored for a replacement card" do
    registration = create_registration
    subscription = registration.subscription
    subscription.update!(stripe_mandate_id: "mandate_replacement")
    mandate = Stripe::Mandate.construct_from(
      id: "mandate_replacement",
      status: "active",
      payment_method: "pm_shared"
    )
    allow(ChargeProcessor).to receive(:get_mandate)
      .with(merchant_account, "mandate_replacement")
      .and_return(mandate)

    expect(subscription.indian_card_mandate_for(card.id)).to eq([mandate, "active", nil])
  end

  it "rejects a stored mandate for a different payment method" do
    registration = create_registration
    subscription = registration.subscription
    subscription.update!(stripe_mandate_id: "mandate_other_card")
    mandate = Stripe::Mandate.construct_from(
      id: "mandate_other_card",
      status: "active",
      payment_method: "pm_other"
    )
    allow(ChargeProcessor).to receive(:get_mandate).and_return(mandate)
    allow(ErrorNotifier).to receive(:notify)

    expect(subscription.indian_card_mandate_for(card.id)).to eq([nil, "missing", nil])
  end

  it "pauses renewal without ending access and clears the pause after an active mandate" do
    registration = create_registration
    registration.mark_indian_card_mandate_registration!
    allow(ErrorNotifier).to receive(:notify)

    registration.record_indian_card_mandate_status!("missing")

    subscription = registration.subscription.reload
    expect(subscription).to be_alive
    expect(subscription).to be_renewal_disabled_due_to_indian_card_mandate
    expect(subscription.status).to eq("payment_method_update_required")

    registration.record_indian_card_mandate_status!("active")

    expect(subscription.reload).not_to be_renewal_disabled_due_to_indian_card_mandate
    expect(subscription).to be_alive
  end


  it "shows pending cancellation instead of the mandate stop" do
    registration = create_registration
    registration.mark_indian_card_mandate_registration!
    registration.record_indian_card_mandate_status!("missing")
    registration.subscription.update!(cancelled_at: 1.day.from_now)

    expect(registration.subscription.status).to eq("pending_cancellation")
  end
end
