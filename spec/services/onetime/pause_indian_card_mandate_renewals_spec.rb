# frozen_string_literal: true

require "spec_helper"

describe Onetime::PauseIndianCardMandateRenewals do
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
  let(:mail) { instance_double(ActionMailer::MessageDelivery, deliver_later: true) }

  before do
    allow(MerchantAccount).to receive(:gumroad)
      .with(StripeChargeProcessor.charge_processor_id)
      .and_return(merchant_account)
    allow(CustomerLowPriorityMailer).to receive(:subscription_indian_card_mandate_invalid).and_return(mail)
    Feature.activate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)
  end

  after do
    Feature.deactivate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)
  end

  def create_membership(credit_card: card, link: product, created_at: 2.months.ago)
    purchase = create(
      :membership_purchase,
      link:,
      seller: link.user,
      purchaser: buyer,
      credit_card:,
      merchant_account:,
      stripe_transaction_id: "ch_registration",
      created_at:
    )
    purchase.subscription.update!(user: buyer, credit_card:)
    purchase.subscription
  end

  it "does not write, email, or enqueue on a dry run" do
    subscription = create_membership

    result = nil
    expect do
      result = described_class.process(seller_id: seller.id, dry_run: true)
    end.not_to change { subscription.reload.flags }

    expect(result).to eq(scanned: 1, paused: 1, already_paused: 0, mandate_check_errors: 0)
    expect(subscription).not_to be_renewal_disabled_due_to_indian_card_mandate
    expect(subscription).not_to be_indian_card_mandate_requires_reauthorization
    expect(CustomerLowPriorityMailer).not_to have_received(:subscription_indian_card_mandate_invalid)
    expect(UnsubscribeAndFailWorker.jobs.size).to eq(0)
  end

  it "pauses the at-risk membership, keeps access, and emails once" do
    subscription = create_membership

    result = described_class.process(seller_id: seller.id, dry_run: false)

    expect(result).to eq(scanned: 1, paused: 1, already_paused: 0, mandate_check_errors: 0)
    subscription.reload
    expect(subscription).to be_alive
    expect(subscription).to be_renewal_disabled_due_to_indian_card_mandate
    expect(subscription).to be_indian_card_mandate_requires_reauthorization
    expect(subscription.status).to eq("payment_method_update_required")
    expect(CustomerLowPriorityMailer).to have_received(:subscription_indian_card_mandate_invalid)
      .with(subscription.id).once
  end

  it "does not email again on a second run" do
    subscription = create_membership
    described_class.process(seller_id: seller.id, dry_run: false)

    result = described_class.process(seller_id: seller.id, dry_run: false)

    expect(result).to eq(scanned: 1, paused: 0, already_paused: 1, mandate_check_errors: 0)
    expect(CustomerLowPriorityMailer).to have_received(:subscription_indian_card_mandate_invalid)
      .with(subscription.id).once
  end

  it "leaves UnsubscribeAndFailWorker a no-op for a paused membership" do
    subscription = create_membership
    described_class.process(seller_id: seller.id, dry_run: false)

    UnsubscribeAndFailWorker.new.perform(subscription.id)

    subscription.reload
    expect(subscription).to be_alive
    expect(subscription.failed_at).to be_nil
  end

  it "skips memberships whose card is not an Indian Stripe card" do
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
    subscription = create_membership(credit_card: non_indian_card)

    result = described_class.process(seller_id: seller.id, dry_run: false)

    expect(result).to eq(scanned: 1, paused: 0, already_paused: 0, mandate_check_errors: 0)
    expect(subscription.reload).not_to be_renewal_disabled_due_to_indian_card_mandate
  end

  it "skips memberships of a seller without the feature flag" do
    other_seller = create(:user)
    other_product = create(:subscription_product, user: other_seller)
    subscription = create_membership(link: other_product)

    result = described_class.process(seller_id: other_seller.id, dry_run: false)

    expect(result).to eq(scanned: 1, paused: 0, already_paused: 0, mandate_check_errors: 0)
    expect(subscription.reload).not_to be_renewal_disabled_due_to_indian_card_mandate
    expect(CustomerLowPriorityMailer).not_to have_received(:subscription_indian_card_mandate_invalid)
  end

  it "skips memberships with no future charge" do
    subscription = create_membership
    subscription.update!(charge_occurrence_count: 1)

    result = described_class.process(seller_id: seller.id, dry_run: false)

    expect(result).to eq(scanned: 1, paused: 0, already_paused: 0, mandate_check_errors: 0)
    expect(subscription.reload).not_to be_renewal_disabled_due_to_indian_card_mandate
    expect(CustomerLowPriorityMailer).not_to have_received(:subscription_indian_card_mandate_invalid)
  end

  it "pauses and emails a membership that was renewal-disabled without reauthorization" do
    subscription = create_membership
    subscription.update_flag!(:renewal_disabled_due_to_indian_card_mandate, true, true)

    result = described_class.process(seller_id: seller.id, dry_run: false)

    expect(result).to eq(scanned: 1, paused: 1, already_paused: 0, mandate_check_errors: 0)
    subscription.reload
    expect(subscription).to be_indian_card_mandate_requires_reauthorization
    expect(CustomerLowPriorityMailer).to have_received(:subscription_indian_card_mandate_invalid)
      .with(subscription.id).once
  end

  it "skips dead memberships" do
    subscription = create_membership
    subscription.update!(failed_at: Time.current, deactivated_at: Time.current)

    result = described_class.process(seller_id: seller.id, dry_run: false)

    expect(result).to eq(scanned: 0, paused: 0, already_paused: 0, mandate_check_errors: 0)
  end

  it "leaves a membership with a non-USD fixing and an active mandate alone" do
    subscription = create_membership
    create(
      :later_charge_presentment,
      owner: subscription,
      presentment_currency: Currency::INR,
      presentment_price_cents: 80_000,
      canonical_price_cents: LaterChargePresentment.canonical_price_cents_for(subscription.original_purchase),
      signup_currency_units_per_usd: BigDecimal("80")
    )
    mandate = Stripe::Mandate.construct_from(id: "mandate_active", status: "active", payment_method: "pm_shared")
    allow_any_instance_of(Subscription).to receive(:indian_card_mandate_for)
      .with(card.id).and_return([mandate, "active", nil])

    result = described_class.process(seller_id: seller.id, dry_run: false)

    expect(result).to eq(scanned: 1, paused: 0, already_paused: 0, mandate_check_errors: 0)
    expect(subscription.reload).not_to be_renewal_disabled_due_to_indian_card_mandate
  end

  it "leaves a pending registration to the mandate check job" do
    subscription = create_membership
    create(
      :later_charge_presentment,
      owner: subscription,
      presentment_currency: Currency::INR,
      presentment_price_cents: 80_000,
      canonical_price_cents: LaterChargePresentment.canonical_price_cents_for(subscription.original_purchase),
      signup_currency_units_per_usd: BigDecimal("80")
    )
    allow_any_instance_of(Subscription).to receive(:indian_card_mandate_for)
      .with(card.id).and_return([nil, "pending", nil])

    result = described_class.process(seller_id: seller.id, dry_run: false)

    expect(result).to eq(scanned: 1, paused: 0, already_paused: 0, mandate_check_errors: 0)
    expect(subscription.reload).not_to be_renewal_disabled_due_to_indian_card_mandate
  end

  it "pauses a membership with a non-USD fixing whose mandate is not active" do
    subscription = create_membership
    create(
      :later_charge_presentment,
      owner: subscription,
      presentment_currency: Currency::INR,
      presentment_price_cents: 80_000,
      canonical_price_cents: LaterChargePresentment.canonical_price_cents_for(subscription.original_purchase),
      signup_currency_units_per_usd: BigDecimal("80")
    )
    allow_any_instance_of(Subscription).to receive(:indian_card_mandate_for)
      .with(card.id).and_return([nil, "inactive", nil])

    result = described_class.process(seller_id: seller.id, dry_run: false)

    expect(result).to eq(scanned: 1, paused: 1, already_paused: 0, mandate_check_errors: 0)
    expect(subscription.reload).to be_renewal_disabled_due_to_indian_card_mandate
  end

  it "pauses a membership whose fixing cannot satisfy the required renewal currency" do
    inr_product = create(:subscription_product, user: seller)
    Redis::Namespace.new(:currencies, redis: $redis).set("INR", "80")
    subscription = create_membership(link: inr_product)
    inr_product.update_column(:price_currency_type, Currency::INR)
    subscription.original_purchase.update_columns(
      displayed_price_currency_type: Currency::INR,
      rate_converted_to_usd: "80"
    )
    create(
      :later_charge_presentment,
      owner: subscription,
      presentment_currency: Currency::NZD,
      presentment_price_cents: 1_700,
      canonical_price_cents: LaterChargePresentment.canonical_price_cents_for(subscription.original_purchase),
      signup_currency_units_per_usd: BigDecimal("1.7")
    )

    expect_any_instance_of(Subscription).not_to receive(:indian_card_mandate_for)

    result = described_class.process(seller_id: seller.id, dry_run: false)

    expect(result).to eq(scanned: 1, paused: 1, already_paused: 0, mandate_check_errors: 0)
    expect(subscription.reload).to be_renewal_disabled_due_to_indian_card_mandate
  end

  it "pauses a membership whose fixing predates the current plan" do
    inr_product = create(:subscription_product, user: seller)
    Redis::Namespace.new(:currencies, redis: $redis).set("INR", "80")
    subscription = create_membership(link: inr_product)
    inr_product.update_column(:price_currency_type, Currency::INR)
    subscription.original_purchase.update_columns(
      displayed_price_currency_type: Currency::INR,
      rate_converted_to_usd: "80"
    )
    create(
      :later_charge_presentment,
      owner: subscription,
      presentment_currency: Currency::INR,
      presentment_price_cents: 72_000,
      canonical_price_cents: LaterChargePresentment.canonical_price_cents_for(subscription.original_purchase) + 1_00,
      signup_currency_units_per_usd: BigDecimal("80")
    )

    expect_any_instance_of(Subscription).not_to receive(:indian_card_mandate_for)

    result = described_class.process(seller_id: seller.id, dry_run: false)

    expect(result).to eq(scanned: 1, paused: 1, already_paused: 0, mandate_check_errors: 0)
    expect(subscription.reload).to be_renewal_disabled_due_to_indian_card_mandate
  end

  it "does not treat a cross-currency fixing price as a plan change" do
    subscription = create_membership
    # A quote-lane INR fixing on a USD-listed membership: its fixed price never equals the
    # listed USD price, and that difference alone must not pause an active mandate.
    create(
      :later_charge_presentment,
      owner: subscription,
      presentment_currency: Currency::INR,
      presentment_price_cents: 80_000,
      canonical_price_cents: LaterChargePresentment.canonical_price_cents_for(subscription.original_purchase),
      signup_currency_units_per_usd: BigDecimal("80")
    )
    mandate = Stripe::Mandate.construct_from(id: "mandate_active", status: "active", payment_method: "pm_shared")
    allow_any_instance_of(Subscription).to receive(:indian_card_mandate_for)
      .with(card.id).and_return([mandate, "active", nil])

    result = described_class.process(seller_id: seller.id, dry_run: false)

    expect(result).to eq(scanned: 1, paused: 0, already_paused: 0, mandate_check_errors: 0)
    expect(subscription.reload).not_to be_renewal_disabled_due_to_indian_card_mandate
  end

  it "leaves a membership alone after a normal FX re-fixing" do
    inr_product = create(:subscription_product, user: seller)
    Redis::Namespace.new(:currencies, redis: $redis).set("INR", "80")
    subscription = create_membership(link: inr_product)
    inr_product.update_column(:price_currency_type, Currency::INR)
    subscription.original_purchase.update_columns(
      displayed_price_currency_type: Currency::INR,
      displayed_price_cents: 80_000,
      rate_converted_to_usd: "80"
    )
    # An FX re-fixing keeps the fixed price and moves only the canonical USD value.
    create(
      :later_charge_presentment,
      owner: subscription,
      presentment_currency: Currency::INR,
      presentment_price_cents: 80_000,
      canonical_price_cents: LaterChargePresentment.canonical_price_cents_for(subscription.original_purchase) + 1_00,
      signup_currency_units_per_usd: BigDecimal("85")
    )
    mandate = Stripe::Mandate.construct_from(id: "mandate_active", status: "active", payment_method: "pm_shared")
    allow_any_instance_of(Subscription).to receive(:indian_card_mandate_for)
      .with(card.id).and_return([mandate, "active", nil])

    result = described_class.process(seller_id: seller.id, dry_run: false)

    expect(result).to eq(scanned: 1, paused: 0, already_paused: 0, mandate_check_errors: 0)
    expect(subscription.reload).not_to be_renewal_disabled_due_to_indian_card_mandate
  end

  it "pauses a membership whose fixing collapses to canonical USD terms" do
    subscription = create_membership
    # An NZD fixing cannot carry an India mandate, and the USD-listed product offers no
    # recovery currency, so terms fall back to USD — incoherent with the stored fixing.
    create(
      :later_charge_presentment,
      owner: subscription,
      presentment_currency: Currency::NZD,
      presentment_price_cents: 1_700,
      canonical_price_cents: LaterChargePresentment.canonical_price_cents_for(subscription.original_purchase),
      signup_currency_units_per_usd: BigDecimal("1.7")
    )

    expect_any_instance_of(Subscription).not_to receive(:indian_card_mandate_for)

    result = described_class.process(seller_id: seller.id, dry_run: false)

    expect(result).to eq(scanned: 1, paused: 1, already_paused: 0, mandate_check_errors: 0)
    expect(subscription.reload).to be_renewal_disabled_due_to_indian_card_mandate
  end

  it "leaves a full-price fixing alone after a limited-duration discount expires" do
    inr_product = create(:subscription_product, user: seller)
    Redis::Namespace.new(:currencies, redis: $redis).set("INR", "80")
    subscription = create_membership(link: inr_product)
    inr_product.update_column(:price_currency_type, Currency::INR)
    # The signup purchase keeps the discounted price; the renewal lane re-fixed the full
    # price when the discount ran out.
    subscription.original_purchase.update_columns(
      displayed_price_currency_type: Currency::INR,
      displayed_price_cents: 40_000,
      rate_converted_to_usd: "80"
    )
    allow_any_instance_of(Subscription).to receive(:current_subscription_price_cents).and_return(80_000)
    allow_any_instance_of(Subscription).to receive(:renewal_pre_discount_total_cents).and_return(80_000)
    create(
      :later_charge_presentment,
      owner: subscription,
      presentment_currency: Currency::INR,
      presentment_price_cents: 80_000,
      canonical_price_cents: 10_00,
      signup_currency_units_per_usd: BigDecimal("80")
    )
    mandate = Stripe::Mandate.construct_from(id: "mandate_active", status: "active", payment_method: "pm_shared")
    allow_any_instance_of(Subscription).to receive(:indian_card_mandate_for)
      .with(card.id).and_return([mandate, "active", nil])

    result = described_class.process(seller_id: seller.id, dry_run: false)

    expect(result).to eq(scanned: 1, paused: 0, already_paused: 0, mandate_check_errors: 0)
    expect(subscription.reload).not_to be_renewal_disabled_due_to_indian_card_mandate
  end

  it "does not pause a membership that recovers during the scan" do
    subscription = create_membership
    service = described_class.new(seller_id: seller.id, dry_run: false)
    allow(service).to receive(:at_risk?).and_wrap_original do |original, sub, checked_card|
      sub.update!(stripe_mandate_id: "mandate_recovered_mid_scan")
      original.call(sub, checked_card)
    end

    result = service.process

    expect(result).to eq(scanned: 1, paused: 0, already_paused: 0, mandate_check_errors: 0)
    expect(subscription.reload).not_to be_renewal_disabled_due_to_indian_card_mandate
    expect(subscription).not_to be_indian_card_mandate_requires_reauthorization
    expect(CustomerLowPriorityMailer).not_to have_received(:subscription_indian_card_mandate_invalid)
  end

  it "skips a membership when the mandate check fails" do
    subscription = create_membership
    create(
      :later_charge_presentment,
      owner: subscription,
      presentment_currency: Currency::INR,
      presentment_price_cents: 80_000,
      canonical_price_cents: LaterChargePresentment.canonical_price_cents_for(subscription.original_purchase),
      signup_currency_units_per_usd: BigDecimal("80")
    )
    allow_any_instance_of(Subscription).to receive(:indian_card_mandate_for)
      .and_raise(ChargeProcessorUnavailableError)
    allow(ErrorNotifier).to receive(:notify)

    result = described_class.process(seller_id: seller.id, dry_run: false)

    expect(result).to eq(scanned: 1, paused: 0, already_paused: 0, mandate_check_errors: 1)
    expect(subscription.reload).not_to be_renewal_disabled_due_to_indian_card_mandate
    expect(ErrorNotifier).to have_received(:notify).once
  end

  it "does not notify the error tracker when a mandate check fails on a dry run" do
    subscription = create_membership
    create(
      :later_charge_presentment,
      owner: subscription,
      presentment_currency: Currency::INR,
      presentment_price_cents: 80_000,
      canonical_price_cents: LaterChargePresentment.canonical_price_cents_for(subscription.original_purchase),
      signup_currency_units_per_usd: BigDecimal("80")
    )
    allow_any_instance_of(Subscription).to receive(:indian_card_mandate_for)
      .and_raise(ChargeProcessorUnavailableError)

    expect(ErrorNotifier).not_to receive(:notify)

    result = described_class.process(seller_id: seller.id, dry_run: true)

    expect(result).to eq(scanned: 1, paused: 0, already_paused: 0, mandate_check_errors: 1)
  end

  it "does not check Stripe for memberships without a stored fixing" do
    create_membership

    expect_any_instance_of(Subscription).not_to receive(:indian_card_mandate_for)

    described_class.process(seller_id: seller.id, dry_run: true)
  end
end
