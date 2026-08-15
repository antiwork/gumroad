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

  it "does not classify UPI mandate failures as card mandate failures" do
    upi_card = CreditCard.create!(
      charge_processor_id: StripeChargeProcessor.charge_processor_id,
      payment_method_type: "upi",
      stripe_customer_id: "cus_upi_renewal",
      processor_payment_method_id: "pm_upi_renewal",
      stripe_fingerprint: "pm_upi_renewal",
      visual: "UPI",
      card_type: CardType::UPI,
      card_country: Compliance::Countries::IND.alpha2,
      recurring_authorization_verified_at: Time.current,
      recurring_authorization_currency: Currency::INR,
      recurring_authorization_max_amount_cents: 100_000
    )
    renewal = create(
      :recurring_membership_purchase,
      link: product,
      seller:,
      credit_card: upi_card,
      stripe_error_code: "india_recurring_payment_mandate_canceled"
    )

    expect(renewal.indian_card_mandate_error_status).to be_nil
  end

  it "omits the interval count for a two-year registration mandate" do
    registration = create_registration
    allow(registration).to receive(:subscription_duration).and_return("every_two_years")
    allow(registration).to receive(:chargeable).and_return(double(requires_mandate?: true))

    mandate_terms = registration.mandate_options_for_stripe
      .dig(:payment_method_options, :card, :mandate_options)

    expect(mandate_terms).to include(interval: "sporadic")
    expect(mandate_terms).not_to have_key(:interval_count)
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

  it "requires the INR mandate currency for renewal presentment" do
    registration = create_registration
    subscription = registration.subscription
    renewal = build(
      :purchase,
      link: product,
      seller:,
      purchaser: buyer,
      subscription:,
      credit_card: card,
      merchant_account:,
      charge_processor_id: StripeChargeProcessor.charge_processor_id,
      is_original_subscription_purchase: false,
      total_transaction_cents: 10_00
    )
    allow(subscription).to receive(:indian_card_mandate_terms).and_return(
      amount: 80_000,
      currency: Currency::INR,
      interval: "month",
      interval_count: 1
    )
    presentment = Purchase::LaterChargePresentmentService::Result.new(
      processor_amount_cents: 80_000,
      processor_currency: Currency::INR,
      processor_gumroad_amount_cents: 8_000,
      stripe_fx_quote_id: "fxq_renewal"
    )
    presentment_service = instance_double(Purchase::LaterChargePresentmentService, perform: presentment)
    expect(Purchase::LaterChargePresentmentService).to receive(:new).with(
      hash_including(
        purchases: [renewal],
        required_currency: Currency::INR,
        required_currency_error_code: PurchaseErrorCode::INDIA_CARD_MANDATE_MISSING
      )
    ).and_return(presentment_service)

    expect(renewal.send(:later_charge_presentment_processor_args, off_session: true)).to include(
      processor_currency: Currency::INR,
      stripe_fx_quote_id: "fxq_renewal"
    )
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

  it "uses a shared charge PaymentIntent bound to the subscription purchase" do
    registration = create_registration
    registration.update_columns(stripe_transaction_id: nil)
    registration.mark_indian_card_mandate_registration!
    charge = create(
      :charge,
      order: create(:order),
      seller:,
      merchant_account:,
      stripe_payment_intent_id: "pi_mixed_cart_mandate"
    )
    charge.purchases << registration
    processor_charge = instance_double(StripeCharge, card_mandate: "mandate_mixed_cart")
    charge_intent = instance_double(
      StripeChargeIntent,
      succeeded?: true,
      payment_method_id: card.processor_payment_method_id,
      charge: processor_charge
    )
    mandate = Stripe::Mandate.construct_from(
      id: "mandate_mixed_cart",
      status: "active",
      payment_method: card.processor_payment_method_id
    )
    allow(ChargeProcessor).to receive(:get_charge_intent)
      .with(merchant_account, "pi_mixed_cart_mandate")
      .and_return(charge_intent)
    allow(ChargeProcessor).to receive(:get_mandate)
      .with(merchant_account, "mandate_mixed_cart")
      .and_return(mandate)

    expect(registration.subscription.indian_card_mandate_for(card.id)).to eq([mandate, "active", registration])
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
    expect(subscription.status).to eq("payment_method_update_required")
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

  it "uses USD when the renewal currency cannot carry an India mandate" do
    registration = create_registration
    subscription = registration.subscription
    allow(subscription).to receive(:original_purchase).and_return(registration)
    allow(registration).to receive(:mandate_maximum_amount_cents).and_return(12_50)
    allow(registration).to receive(:mandate_maximum_displayed_price_cents).and_return(12_50)
    canonical_price_cents = LaterChargePresentment.canonical_price_cents_for(registration)
    create(
      :later_charge_presentment,
      owner: subscription,
      presentment_currency: Currency::NZD,
      presentment_price_cents: 2_000,
      canonical_price_cents:,
      signup_currency_units_per_usd: BigDecimal("1.6")
    )

    expect(subscription.indian_card_mandate_terms).to include(
      amount: 12_50,
      currency: Currency::USD
    )
  end

  it "keeps a destination renewal mandate in the supported canonical currency" do
    registration = create_registration
    subscription = registration.subscription
    destination_account = create(
      :merchant_account,
      user: seller,
      charge_processor_id: StripeChargeProcessor.charge_processor_id,
      charge_processor_merchant_id: "acct_destination"
    )
    allow(subscription).to receive(:renewal_merchant_account).and_return(destination_account)
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
      amount: 12_50,
      currency: Currency::USD
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

    expect(registration.mandate_maximum_amount_cents).to eq(renewal_price_cents)
    expect(subscription.indian_card_mandate_terms).to include(
      amount: renewal_price_cents * 80,
      currency: Currency::INR
    )
  end

  it "uses the paid renewal amount when a free trial charges shipping" do
    product = create(:membership_product_with_preset_tiered_pricing, :with_free_trial_enabled)
    registration = create(
      :free_trial_membership_purchase,
      link: product,
      displayed_price_cents: 0,
      price_cents: 0,
      shipping_cents: 2_00,
      total_transaction_cents: 2_00
    )
    allow(registration.subscription).to receive(:current_subscription_price_cents).and_return(10_00)

    expect(registration.mandate_maximum_amount_cents).to eq(12_00)
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

  it "shows the payment update state during a temporary free renewal" do
    registration = create_registration
    registration.update!(displayed_price_cents: 0)
    registration.create_purchase_offer_code_discount!(
      offer_code: create(:offer_code, products: [product]),
      offer_code_amount: 100,
      offer_code_is_percent: true,
      pre_discount_minimum_price_cents: 10_00,
      duration_in_billing_cycles: 2
    )
    subscription = registration.subscription.reload
    subscription.update_flag!(:renewal_disabled_due_to_indian_card_mandate, true, true)

    expect(subscription.current_subscription_price_cents).to eq(0)
    expect(subscription).to be_future_subscription_charge
    expect(subscription.status).to eq("payment_method_update_required")
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

  it "does not let an old registration replace a newer mandate" do
    old_registration = create_registration
    subscription = old_registration.subscription
    old_registration.mark_indian_card_mandate_registration!
    new_registration = create(
      :purchase,
      link: product,
      seller:,
      purchaser: buyer,
      subscription:,
      credit_card: card,
      merchant_account:,
      stripe_transaction_id: "ch_new_registration",
      created_at: old_registration.created_at + 1.second
    )
    new_registration.mark_indian_card_mandate_registration!
    subscription.update!(stripe_mandate_id: "mandate_new")

    old_registration.record_indian_card_mandate_status!("active", mandate_id: "mandate_old")

    expect(subscription.reload.stripe_mandate_id).to eq("mandate_new")
  end

  it "restores the prior mandate after a changed-plan payment fails" do
    registration = create_registration
    subscription = registration.subscription
    subscription.update!(stripe_mandate_id: "mandate_prior_plan")

    subscription.require_indian_card_mandate_reauthorization!

    expect(subscription.reload).to be_renewal_disabled_due_to_indian_card_mandate
    expect(subscription).to be_indian_card_mandate_requires_reauthorization
    expect(subscription.stripe_mandate_id).to eq("mandate_prior_plan")

    subscription.restore_indian_card_mandate_after_failed_reauthorization!

    expect(subscription.reload).not_to be_renewal_disabled_due_to_indian_card_mandate
    expect(subscription).not_to be_indian_card_mandate_requires_reauthorization
    expect(subscription.stripe_mandate_id).to eq("mandate_prior_plan")
  end

  it "invalidates a replacement mandate after the changed plan rolls back" do
    registration = create_registration
    subscription = registration.subscription
    subscription.update!(stripe_mandate_id: "mandate_prior_plan")
    subscription.require_indian_card_mandate_reauthorization!
    replacement_card = CreditCard.create!(
      charge_processor_id: StripeChargeProcessor.charge_processor_id,
      stripe_customer_id: "cus_replacement",
      processor_payment_method_id: "pm_replacement",
      stripe_fingerprint: "fingerprint_replacement",
      visual: "**** **** **** 4242",
      card_type: CardType::VISA,
      card_country: Compliance::Countries::IND.alpha2,
      expiry_month: 12,
      expiry_year: 2030
    )
    subscription.update!(
      credit_card: replacement_card,
      stripe_mandate_id: "mandate_replacement_plan",
      renewal_disabled_due_to_indian_card_mandate: false,
      indian_card_mandate_requires_reauthorization: false
    )

    subscription.restore_indian_card_mandate_after_failed_reauthorization!(expected_credit_card_id: card.id)

    expect(subscription.reload).to be_renewal_disabled_due_to_indian_card_mandate
    expect(subscription).to be_indian_card_mandate_requires_reauthorization
    expect(subscription.stripe_mandate_id).to be_nil
  end

  it "clears plan reauthorization after a confirmed charge registers matching terms" do
    registration = create_registration
    subscription = registration.subscription
    subscription.update_flag!(:renewal_disabled_due_to_indian_card_mandate, true, true)
    subscription.update_flag!(:indian_card_mandate_requires_reauthorization, true, true)
    registration.mark_indian_card_mandate_registration!
    allow(registration).to receive(:processor_payment_intent_id).and_return("pi_matching_terms")
    terms = subscription.indian_card_mandate_terms
    mandate_options = Stripe::StripeObject.construct_from(
      amount: terms[:amount],
      amount_type: "maximum",
      interval: terms[:interval],
      interval_count: terms[:interval_count],
      supported_types: ["india"]
    )
    intent = instance_double(
      StripeChargeIntent,
      succeeded?: true,
      payment_method_id: card.processor_payment_method_id,
      customer_id: card.stripe_customer_id,
      setup_future_usage: "off_session",
      currency: terms[:currency],
      card_mandate_options: mandate_options
    )
    allow(ChargeProcessor).to receive(:get_charge_intent).with(merchant_account, "pi_matching_terms").and_return(intent)

    registration.record_indian_card_mandate_status!("active", mandate_id: "mandate_matching_terms")

    expect(subscription.reload).not_to be_renewal_disabled_due_to_indian_card_mandate
    expect(subscription).not_to be_indian_card_mandate_requires_reauthorization
    expect(subscription.stripe_mandate_id).to eq("mandate_matching_terms")
  end

  it "clears plan reauthorization for matching sporadic terms" do
    registration = create_registration
    subscription = registration.subscription
    subscription.update_flag!(:renewal_disabled_due_to_indian_card_mandate, true, true)
    subscription.update_flag!(:indian_card_mandate_requires_reauthorization, true, true)
    registration.mark_indian_card_mandate_registration!
    allow(registration).to receive(:processor_payment_intent_id).and_return("pi_sporadic_terms")
    terms = {
      amount: 10_00,
      currency: Currency::USD,
      interval: "sporadic",
      interval_count: nil
    }
    allow_any_instance_of(Subscription).to receive(:indian_card_mandate_terms).and_return(terms)
    mandate_options = Stripe::StripeObject.construct_from(
      amount: terms[:amount],
      amount_type: "maximum",
      interval: terms[:interval],
      interval_count: nil,
      supported_types: ["india"]
    )
    intent = instance_double(
      StripeChargeIntent,
      succeeded?: true,
      payment_method_id: card.processor_payment_method_id,
      customer_id: card.stripe_customer_id,
      setup_future_usage: "off_session",
      currency: terms[:currency],
      card_mandate_options: mandate_options
    )
    allow(ChargeProcessor).to receive(:get_charge_intent).with(merchant_account, "pi_sporadic_terms").and_return(intent)

    registration.record_indian_card_mandate_status!("active", mandate_id: "mandate_sporadic_terms")

    expect(subscription.reload).not_to be_renewal_disabled_due_to_indian_card_mandate
    expect(subscription).not_to be_indian_card_mandate_requires_reauthorization
    expect(subscription.stripe_mandate_id).to eq("mandate_sporadic_terms")
  end

  it "keeps plan reauthorization when a confirmed charge has different terms" do
    registration = create_registration
    subscription = registration.subscription
    subscription.update_flag!(:renewal_disabled_due_to_indian_card_mandate, true, true)
    subscription.update_flag!(:indian_card_mandate_requires_reauthorization, true, true)
    registration.mark_indian_card_mandate_registration!
    allow(registration).to receive(:processor_payment_intent_id).and_return("pi_old_terms")
    terms = subscription.indian_card_mandate_terms
    mandate_options = Stripe::StripeObject.construct_from(
      amount: terms[:amount] - 1,
      amount_type: "maximum",
      interval: terms[:interval],
      interval_count: terms[:interval_count],
      supported_types: ["india"]
    )
    intent = instance_double(
      StripeChargeIntent,
      succeeded?: true,
      payment_method_id: card.processor_payment_method_id,
      customer_id: card.stripe_customer_id,
      setup_future_usage: "off_session",
      currency: terms[:currency],
      card_mandate_options: mandate_options
    )
    allow(ChargeProcessor).to receive(:get_charge_intent).with(merchant_account, "pi_old_terms").and_return(intent)

    registration.record_indian_card_mandate_status!("active", mandate_id: "mandate_old_terms")

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
    subscription.update!(
      stripe_mandate_id: "mandate_old_card",
      renewal_disabled_due_to_indian_card_mandate: true,
      indian_card_mandate_requires_reauthorization: true,
      credit_card: nil
    )
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
    expect(subscription.reload).to have_attributes(
      stripe_mandate_id: nil,
      renewal_disabled_due_to_indian_card_mandate: false,
      indian_card_mandate_requires_reauthorization: false
    )
  end


  it "shows pending cancellation instead of the mandate stop" do
    registration = create_registration
    registration.mark_indian_card_mandate_registration!
    registration.record_indian_card_mandate_status!("missing")
    registration.subscription.update!(cancelled_at: 1.day.from_now)

    expect(registration.subscription.status).to eq("pending_cancellation")
  end

  it "shows a mandate failure until the renewal stop is recorded" do
    Feature.deactivate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)
    registration = create_registration
    create(
      :failed_purchase,
      link: product,
      seller:,
      purchaser: buyer,
      subscription: registration.subscription,
      credit_card: card,
      error_code: PurchaseErrorCode::INDIA_CARD_MANDATE_MISSING,
      created_at: registration.created_at + 1.second
    )
    Feature.activate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)

    expect(registration.subscription.reload).not_to be_renewal_disabled_due_to_indian_card_mandate
    expect(registration.subscription.status).to eq("pending_failure")
  end

  it "does not load route data when the mandate stop is clear" do
    subscription = create_registration.subscription
    allow(subscription).to receive(:pending_failure?).and_return(false)
    expect(subscription).not_to receive(:india_card_mandate_reliability_enabled?)

    expect(subscription.status).to eq("alive")
  end
end
