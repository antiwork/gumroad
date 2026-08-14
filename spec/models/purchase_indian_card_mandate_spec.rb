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

  it "maps Stripe's inactive-mandate failures only when enforcement is on" do
    registration = create_registration

    ["payment_intent_mandate_invalid", "india_recurring_payment_mandate_canceled"].each do |error_code|
      registration.stripe_error_code = error_code
      expect(registration.indian_card_mandate_error_status).to eq("inactive")
    end

    Feature.deactivate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)
    expect(registration.indian_card_mandate_error_status).to be_nil
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

  it "uses the source charge payment method for a legacy card" do
    registration = create_registration
    registration.mark_indian_card_mandate_registration!
    card.update_column(:processor_payment_method_id, nil)
    mandate = Stripe::Mandate.construct_from(id: "mandate_legacy", status: "active", payment_method: "pm_shared")
    processor_charge = instance_double(
      BaseProcessorCharge,
      card_mandate: "mandate_legacy",
      card_instance_id: "pm_shared"
    )
    allow(ChargeProcessor).to receive(:get_charge).and_return(processor_charge)
    allow(ChargeProcessor).to receive(:get_mandate).and_return(mandate)

    expect(registration.retrieve_indian_card_mandate).to eq([mandate, "active"])
  end

  it "keeps the registration check when another save follows the success transition" do
    registration = create_registration
    registration.update_column(:purchase_state, "in_progress")
    registration.reload.mark_indian_card_mandate_registration!
    expect(CheckIndianCardMandateRegistrationJob).to receive(:perform_async).with(registration.id)

    ActiveRecord::Base.transaction do
      registration.mark_successful!
      registration.save!
    end
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

  it "keeps using the source binding when a legacy card has no payment method ID" do
    registration = create_registration
    subscription = registration.subscription
    card.update!(processor_payment_method_id: nil)
    mandate = Stripe::Mandate.construct_from(
      id: "mandate_legacy",
      status: "active",
      payment_method: "pm_legacy"
    )
    allow(subscription).to receive(:indian_card_mandate_source_purchase).with(card.id).and_return(registration)
    allow(registration).to receive(:retrieve_indian_card_mandate).and_return([mandate, "active"])

    expect(subscription.indian_card_mandate_for(card.id)).to eq([mandate, "active", registration])
    registration.record_indian_card_mandate_status!("active", mandate_id: mandate.id)

    expect(subscription.reload.stripe_mandate_id).to be_nil
    expect(subscription.indian_card_mandate_for(card.id)).to eq([mandate, "active", registration])
  end

  it "preserves access after Stripe rejects an inactive mandate" do
    registration = create_registration
    subscription = registration.subscription
    renewal = create(
      :purchase,
      link: product,
      seller:,
      purchaser: buyer,
      subscription:,
      credit_card: card,
      merchant_account:,
      card_country: Compliance::Countries::IND.alpha2,
      purchase_state: "in_progress",
      stripe_error_code: "payment_intent_mandate_invalid"
    )
    mail = instance_double(ActionMailer::MessageDelivery, deliver_later: true)
    allow(CustomerLowPriorityMailer).to receive(:subscription_indian_card_mandate_invalid).with(subscription.id).and_return(mail)
    expect(UnsubscribeAndFailWorker).not_to receive(:perform_in)

    subscription.handle_purchase_failure(renewal)

    expect(renewal.reload).to be_failed
    expect(subscription.reload).to be_alive
    expect(subscription).to be_renewal_disabled_due_to_indian_card_mandate
  end

  it "converts the server-owned full renewal cap into the stored renewal currency" do
    registration = create_registration
    subscription = registration.subscription
    allow(subscription).to receive(:original_purchase).and_return(registration)
    allow(registration).to receive(:mandate_maximum_amount_cents).and_return(12_50)
    allow(registration).to receive(:mandate_maximum_displayed_price_cents).and_return(12_50)
    canonical_price_cents = LaterChargePresentment.canonical_price_cents_for(registration)
    create(
      :later_charge_presentment,
      owner: subscription,
      presentment_currency: Currency::INR,
      presentment_price_cents: 49_950,
      canonical_price_cents:,
      signup_currency_units_per_usd: BigDecimal("83.25")
    )

    expect(subscription.indian_card_mandate_terms).to include(
      amount: 104_063,
      currency: Currency::INR
    )
  end

  it "uses the future renewal amount when the signup transaction was free" do
    product = create(:membership_product_with_preset_tiered_pricing, :with_free_trial_enabled)
    registration = create(
      :free_trial_membership_purchase,
      link: product,
      displayed_price_cents: 0,
      price_cents: 0,
      total_transaction_cents: 0
    )
    subscription = registration.subscription
    renewal_price_cents = 10_00
    allow(subscription).to receive(:current_subscription_price_cents).and_return(renewal_price_cents)
    create(
      :later_charge_presentment,
      owner: subscription,
      presentment_currency: Currency::INR,
      presentment_price_cents: renewal_price_cents * 80,
      canonical_price_cents: renewal_price_cents,
      signup_currency_units_per_usd: BigDecimal("80")
    )

    expect(registration.mandate_maximum_amount_cents).to eq(0)
    expect(subscription.indian_card_mandate_terms).to include(
      amount: renewal_price_cents * 80,
      currency: Currency::INR
    )
  end

  it "uses the pre-discount price for a temporary full discount" do
    registration = create_registration
    registration.update!(displayed_price_cents: 0)
    registration.create_purchase_offer_code_discount!(
      offer_code: create(:offer_code, products: [product]),
      offer_code_amount: 100,
      offer_code_is_percent: true,
      pre_discount_minimum_price_cents: 10_00,
      duration_in_billing_cycles: 1
    )

    expect(registration.mandate_maximum_displayed_price_cents).to eq(10_00)
  end

  it "recomputes the canonical mandate cap for the submitted billing location" do
    registration = create_registration
    subscription = registration.subscription
    source_purchase = subscription.original_purchase
    product.update_column(:price_currency_type, Currency::EUR)
    source_purchase.update_columns(
      displayed_price_currency_type: Currency::EUR,
      rate_converted_to_usd: "0.8"
    )
    allow(source_purchase).to receive(:mandate_maximum_displayed_price_cents).and_return(10_00)
    allow(subscription).to receive(:get_rate).with(Currency::EUR).and_return("1.0")
    canonical_price_cents = LaterChargePresentment.canonical_price_cents_for(source_purchase)
    allow(subscription).to receive(:current_later_charge_presentment).and_return(
      instance_double(
        LaterChargePresentment,
        canonical_price_cents:,
        presentment_currency: Currency::EUR,
        signup_currency_units_per_usd: BigDecimal("0.8")
      )
    )
    tax_calculation = instance_double(SalesTaxCalculation, tax_cents: 1_25)
    expect(SalesTaxCalculator).to receive(:new).with(
      product:,
      price_cents: 12_50,
      shipping_cents: 0,
      quantity: source_purchase.quantity,
      buyer_location: {
        postal_code: "94107",
        country: Compliance::Countries::USA.alpha2,
        state: "CA",
        ip_address: source_purchase.ip_address,
      },
      buyer_vat_id: nil,
      from_discover: false
    ).and_return(instance_double(SalesTaxCalculator, calculate: tax_calculation))

    expect(
      subscription.indian_card_mandate_terms(
        billing_info: { country: "United States", state: "CA", zip_code: "94107" }
      )
    ).to include(amount: 11_25, currency: Currency::EUR)
  end

  it "uses the current renewal rate when no later-charge presentment is fixed" do
    registration = create_registration
    subscription = registration.subscription
    source_purchase = subscription.original_purchase
    product.update_column(:price_currency_type, Currency::EUR)
    source_purchase.update_columns(
      displayed_price_currency_type: Currency::EUR,
      rate_converted_to_usd: "0.8"
    )
    allow(source_purchase).to receive(:mandate_maximum_displayed_price_cents).and_return(10_00)
    allow(subscription).to receive(:get_rate).with(Currency::EUR).and_return("1.0")
    allow(SalesTaxCalculator).to receive(:new).and_return(
      instance_double(SalesTaxCalculator, calculate: instance_double(SalesTaxCalculation, tax_cents: 0))
    )

    expect(
      subscription.indian_card_mandate_terms(
        billing_info: { country: "United States", state: "CA", zip_code: "94107" }
      )
    ).to include(amount: 10_00, currency: Currency::USD)
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

  it "does not let an old active registration clear a plan reauthorization" do
    registration = create_registration
    subscription = registration.subscription
    subscription.update!(stripe_mandate_id: nil)
    subscription.update_flag!(:renewal_disabled_due_to_indian_card_mandate, true, true)
    subscription.update_flag!(:indian_card_mandate_requires_reauthorization, true, true)
    subscription.reload

    subscription.update_renewal_for_indian_card_mandate!(
      "active",
      expected_credit_card_id: card.id,
      mandate_id: "mandate_old_plan"
    )

    expect(subscription.reload).to be_renewal_disabled_due_to_indian_card_mandate
    expect(subscription).to be_indian_card_mandate_requires_reauthorization
    expect(subscription.stripe_mandate_id).to be_nil
  end

  it "does not require Stripe reauthorization for a non-Stripe Indian card" do
    registration = create_registration
    subscription = registration.subscription
    card.update_columns(
      charge_processor_id: BraintreeChargeProcessor.charge_processor_id,
      braintree_customer_id: "braintree_customer"
    )

    subscription.require_indian_card_mandate_reauthorization!

    expect(subscription.reload).not_to be_renewal_disabled_due_to_indian_card_mandate
    expect(subscription).not_to be_indian_card_mandate_requires_reauthorization
  end

  it "clears the pause when the effective payment method is not an Indian card" do
    registration = create_registration
    subscription = registration.subscription
    subscription.update!(renewal_disabled_due_to_indian_card_mandate: true, credit_card: nil)
    non_indian_card = CreditCard.create!(
      charge_processor_id: StripeChargeProcessor.charge_processor_id,
      stripe_customer_id: "cus_non_indian",
      processor_payment_method_id: "pm_non_indian",
      stripe_fingerprint: "fingerprint_non_indian",
      visual: "**** **** **** 4242",
      card_type: CardType::VISA,
      card_country: Compliance::Countries::USA.alpha2,
      expiry_month: 12,
      expiry_year: 2030
    )
    buyer.update!(credit_card: non_indian_card)

    expect(subscription.reload.refresh_indian_card_mandate!).to eq("active")
    expect(subscription.reload).not_to be_renewal_disabled_due_to_indian_card_mandate
  end


  it "shows pending cancellation instead of the mandate stop" do
    registration = create_registration
    registration.mark_indian_card_mandate_registration!
    registration.record_indian_card_mandate_status!("missing")
    registration.subscription.update!(cancelled_at: 1.day.from_now)

    expect(registration.subscription.status).to eq("pending_cancellation")
  end

  it "does not load route data when the mandate stop is clear" do
    subscription = create_registration.subscription
    allow(subscription).to receive(:pending_failure?).and_return(false)
    expect(subscription).not_to receive(:india_card_mandate_reliability_enabled?)

    expect(subscription.status).to eq("alive")
  end
end
