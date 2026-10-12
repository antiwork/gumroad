# frozen_string_literal: true

require "spec_helper"

# Drives the client's calls in order: /stripe/setup_intents, then the checkout order that carries the returned ids.
# Only Stripe's network calls are stubbed; the chargeable, CreditCard, and restart service are the real ones.
describe Stripe::SetupIntentsController, "resubmitting a restart at checkout whose Indian e-mandate is pending" do
  let(:seller) { create(:user) }
  let(:product) { create(:subscription_product_with_versions, user: seller) }
  let(:guest_email) { "guest@example.com" }
  let(:merchant_account) do
    create(:merchant_account, user: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id, charge_processor_merchant_id: nil)
  end
  let(:old_card) do
    CreditCard.create!(
      charge_processor_id: StripeChargeProcessor.charge_processor_id,
      stripe_customer_id: "cus_old",
      processor_payment_method_id: "pm_old",
      stripe_fingerprint: "fp_old",
      visual: "**** **** **** 1111",
      card_type: CardType::VISA,
      card_country: Compliance::Countries::IND.alpha2,
      expiry_month: 12,
      expiry_year: 2030
    )
  end
  let!(:subscription) do
    subscription = create(:subscription, link: product, user: nil, credit_card: old_card)
    travel_to(2.months.ago) do
      create(:purchase, is_original_subscription_purchase: true, link: product, subscription:, purchaser: nil, email: guest_email,
                        price_cents: product.default_price_cents, credit_card: old_card, variant_attributes: [product.variants.first])
    end
    subscription.update!(cancelled_at: 1.day.ago, cancelled_by_buyer: true, deactivated_at: 1.day.ago)
    subscription
  end
  let(:pending_message) { Subscription::UpdaterService::MANDATE_STILL_PENDING_RESTART_MESSAGE }
  let(:minted_setup_intent_ids) { [] }
  let(:minted_setup_intents) { {} }
  let(:payment_methods) { {} }
  let(:mandate_status) { { value: "pending" } }
  let(:restart_intent) { Checkout::RestartIntentToken.issue(product:, buyer: nil) }

  def payment_method(id)
    payment_methods[id] ||= Stripe::PaymentMethod.construct_from(
      id:,
      type: "card",
      customer: nil,
      card: { brand: "visa", last4: "4242", exp_month: 12, exp_year: 2030, country: "IN", funding: "credit", fingerprint: "fp_new_card" },
      billing_details: { address: { postal_code: "400001" } }
    )
  end

  def setup_intent_double(id, payment_method_id, customer_id)
    terms = subscription.indian_card_mandate_terms
    instance_double(
      StripeSetupIntent,
      id:,
      succeeded?: true,
      requires_action?: false,
      mandate: "mandate_#{id}",
      payment_method_id:,
      customer_id:,
      usage: "off_session",
      metadata: { gumroad_subscription_id: subscription.external_id },
      card_mandate_options: Stripe::StripeObject.construct_from(
        amount_type: "maximum",
        amount: terms[:amount],
        currency: terms[:currency],
        reference: StripeChargeProcessor.indian_card_mandate_reference(subscription.external_id),
        interval: terms[:interval],
        interval_count: terms[:interval_count],
        supported_types: ["india"]
      )
    )
  end

  before do
    cookies[:_gumroad_guid] = SecureRandom.uuid
    allow(MerchantAccount).to receive(:gumroad).with(StripeChargeProcessor.charge_processor_id).and_return(merchant_account)
    Feature.activate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)
    allow(Stripe::PaymentMethod).to receive(:retrieve) { |id, *| payment_method(id) }
    allow(Stripe::Customer).to receive(:create).and_return(Stripe::Customer.construct_from(id: "cus_minted"))
    allow(ChargeProcessor).to receive(:setup_future_charges!) do |_account, chargeable, **|
      minted_setup_intent_ids << "seti_#{minted_setup_intent_ids.size + 1}"
      minted_setup_intents[minted_setup_intent_ids.last] = setup_intent_double(minted_setup_intent_ids.last, chargeable.payment_method_id, "cus_minted")
    end
    allow(ChargeProcessor).to receive(:get_setup_intent) { |_account, id| minted_setup_intents.fetch(id) }
    allow(ChargeProcessor).to receive(:get_mandate) do |_account, id|
      setup_intent = minted_setup_intents.values.find { _1.mandate == id }
      Stripe::Mandate.construct_from(id:, status: mandate_status[:value], payment_method: setup_intent.payment_method_id)
    end
    expect_any_instance_of(Subscription).not_to receive(:charge!)
    CompleteIndianCardMandateJob.clear
  end

  after do
    Feature.deactivate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)
  end

  # What the checkout client does for one submission: ask for a setup intent, then post the order with the ids it got back.
  def submit_restart(payment_method_id)
    @controller = described_class.new
    post :create, params: {
      stripe_payment_method_id: payment_method_id,
      email: guest_email,
      products: [{ price: product.price_cents, permalink: product.unique_permalink }]
    }
    setup_intent = response.parsed_body

    @controller = OrdersController.new
    post :create, params: {
      email: guest_email,
      cc_zipcode_required: "false",
      card_data_handling_mode: "stripejs.0",
      stripe_payment_method_id: setup_intent["payment_method_id"] || payment_method_id,
      stripe_customer_id: setup_intent["reusable_token"],
      stripe_setup_intent_id: setup_intent["setup_intent_id"],
      purchase: { full_name: "Guest Buyer", street_address: "1 MG Road", country: "IN", state: "MH", city: "Mumbai", zip_code: "400001" },
      line_items: [{
        uid: "restart-line",
        permalink: product.unique_permalink,
        perceived_price_cents: product.default_price_cents,
        quantity: 1,
        price_id: subscription.price.external_id,
        variants: [product.variants.first.external_id],
        restart_intent:
      }]
    }
    [setup_intent, response.parsed_body.dig("line_items", "restart-line")]
  end

  it "reuses the one setup intent and mandate across repeated submissions and keeps the restart held" do
    first_intent, first_line = submit_restart("pm_first")

    expect(first_intent).to include("setup_intent_id" => "seti_1", "reusable_token" => "cus_minted")
    expect(first_line).to include("success" => false, "error_message" => pending_message)
    expect(subscription.reload).not_to be_alive
    expect(subscription).to be_indian_card_mandate_restart_held
    expect(subscription.stripe_mandate_id).to eq("mandate_seti_1")
    expect(subscription.credit_card).to have_attributes(
      processor_payment_method_id: "pm_first",
      stripe_customer_id: "cus_minted",
      stripe_setup_intent_id: "seti_1"
    )
    first_card_id = subscription.credit_card.id

    second_intent, second_line = submit_restart("pm_second")

    expect(second_intent).to include("setup_intent_id" => "seti_1", "reusable_token" => "cus_minted", "payment_method_id" => "pm_first")
    expect(second_line).to include("success" => false, "error_message" => pending_message)
    expect(minted_setup_intent_ids).to eq(["seti_1"])
    expect(subscription.reload).not_to be_alive
    expect(subscription.stripe_mandate_id).to eq("mandate_seti_1")
    expect(subscription.credit_card).to have_attributes(processor_payment_method_id: "pm_first", stripe_setup_intent_id: "seti_1")
    expect(subscription.credit_card.id).not_to eq(first_card_id)
    expect(subscription.purchases.not_is_original_subscription_purchase.count).to eq(0)
    expect(RecurringChargeWorker.jobs).to be_empty
  end

  it "returns the retryable provider-unavailable response without minting a second setup intent when the stored mandate lookup is unavailable" do
    submit_restart("pm_first")
    stored_card = subscription.reload.credit_card
    allow(ChargeProcessor).to receive(:get_mandate).and_raise(ChargeProcessorUnavailableError.new("stripe down"))
    expect(ErrorNotifier).to receive(:notify).with(instance_of(ChargeProcessorUnavailableError), subscription: subscription.external_id)

    @controller = described_class.new
    post :create, params: { stripe_payment_method_id: "pm_second", email: guest_email, products: [{ price: product.price_cents, permalink: product.unique_permalink }] }

    expect(response).to have_http_status(:service_unavailable)
    expect(minted_setup_intent_ids).to eq(["seti_1"])
    expect(subscription.reload.credit_card).to eq(stored_card)
    expect(subscription).to be_indian_card_mandate_restart_held
  end

  it "lets only the newest submission's completion chain act, and that chain restarts the membership once the mandate is active" do
    submit_restart("pm_first")
    submit_restart("pm_second")
    older, newer = CompleteIndianCardMandateJob.jobs.map { _1["args"] }

    expect(newer.last).to be > older.last

    CompleteIndianCardMandateJob.new.perform(subscription.id, CheckIndianCardMandateRegistrationJob::PENDING_RECHECK_DELAYS.length, older.last)
    expect(subscription.reload).to be_indian_card_mandate_restart_held

    mandate_status[:value] = "active"
    allow_any_instance_of(Subscription).to receive(:send_restart_notifications!)
    CompleteIndianCardMandateJob.new.perform(subscription.id, 0, newer.last)

    expect(subscription.reload).to be_alive
    expect(subscription).not_to be_indian_card_mandate_restart_held
    expect(RecurringChargeWorker.jobs.map { _1["args"] }).to eq([[subscription.id]])
  end

  it "mints a new setup intent once the abandoned restart's marker has been released" do
    submit_restart("pm_first")
    CompleteIndianCardMandateJob.new.perform(subscription.id, CheckIndianCardMandateRegistrationJob::PENDING_RECHECK_DELAYS.length, CompleteIndianCardMandateJob.jobs.last["args"].last)
    expect(subscription.reload).not_to be_indian_card_mandate_restart_held

    second_intent, second_line = submit_restart("pm_second")

    expect(second_intent).to include("setup_intent_id" => "seti_2")
    expect(second_intent).not_to have_key("payment_method_id")
    expect(minted_setup_intent_ids).to eq(%w[seti_1 seti_2])
    expect(second_line).to include("success" => false, "error_message" => pending_message)
    expect(subscription.reload.stripe_mandate_id).to eq("mandate_seti_2")
    expect(subscription.credit_card.processor_payment_method_id).to eq("pm_second")
  end

  it "mints a new setup intent and uses the entered card once the pending mandate has become active" do
    submit_restart("pm_first")
    mandate_status[:value] = "active"

    # Only the setup intent request: an active mandate lets the restart charge, which this spec forbids.
    @controller = described_class.new
    post :create, params: {
      stripe_payment_method_id: "pm_second",
      email: guest_email,
      products: [{ price: product.price_cents, permalink: product.unique_permalink }]
    }

    expect(response.parsed_body).to include("setup_intent_id" => "seti_2")
    expect(response.parsed_body).not_to have_key("payment_method_id")
    expect(minted_setup_intent_ids).to eq(%w[seti_1 seti_2])
  end

  it "mints a new setup intent once the pending mandate has become inactive" do
    submit_restart("pm_first")
    mandate_status[:value] = "inactive"

    second_intent, = submit_restart("pm_second")

    expect(second_intent).to include("setup_intent_id" => "seti_2")
    expect(minted_setup_intent_ids).to eq(%w[seti_1 seti_2])
  end

  it "mints a new setup intent when the repeat submission comes from a session that did not mint the stored one" do
    submit_restart("pm_first")
    session.delete(described_class::SESSION_SETUP_INTENT_KEY)

    second_intent, = submit_restart("pm_second")

    expect(second_intent).to include("setup_intent_id" => "seti_2")
    expect(second_intent).not_to have_key("payment_method_id")
  end

  def other_card_payment_method(id)
    payment_methods[id] = Stripe::PaymentMethod.construct_from(
      id:,
      type: "card",
      customer: nil,
      card: { brand: "visa", last4: "1881", exp_month: 12, exp_year: 2030, country: "IN", funding: "credit", fingerprint: "fp_other_card" },
      billing_details: { address: { postal_code: "400001" } }
    )
  end

  def request_setup_intent(payment_method_id)
    @controller = described_class.new
    post :create, params: {
      stripe_payment_method_id: payment_method_id,
      email: guest_email,
      products: [{ price: product.price_cents, permalink: product.unique_permalink }]
    }
    response.parsed_body
  end

  it "keeps reusing the stored setup intent when the guest tries a different card and then re-enters the original" do
    submit_restart("pm_first")
    other_card_payment_method("pm_other")

    expect(request_setup_intent("pm_other")).to include("setup_intent_id" => "seti_2")

    third_intent, third_line = submit_restart("pm_again")

    expect(third_intent).to include("setup_intent_id" => "seti_1", "payment_method_id" => "pm_first")
    expect(third_line).to include("success" => false, "error_message" => pending_message)
    expect(minted_setup_intent_ids).to eq(%w[seti_1 seti_2])
    expect(subscription.reload.stripe_mandate_id).to eq("mandate_seti_1")
  end

  it "does not hand the stored setup intent to a session that only minted a different card's intent" do
    submit_restart("pm_first")
    session.delete(described_class::SESSION_SETUP_INTENT_KEY)
    other_card_payment_method("pm_other")
    expect(request_setup_intent("pm_other")).to include("setup_intent_id" => "seti_2")

    third_intent = request_setup_intent("pm_again")

    expect(third_intent).to include("setup_intent_id" => "seti_3")
    expect(third_intent).not_to have_key("payment_method_id")
    expect(minted_setup_intent_ids).to eq(%w[seti_1 seti_2 seti_3])
  end

  it "mints a new setup intent when the buyer submits a different card" do
    submit_restart("pm_first")
    payment_methods["pm_second"] = Stripe::PaymentMethod.construct_from(
      id: "pm_second",
      type: "card",
      customer: nil,
      card: { brand: "visa", last4: "1881", exp_month: 12, exp_year: 2030, country: "IN", funding: "credit", fingerprint: "fp_other_card" },
      billing_details: { address: { postal_code: "400001" } }
    )

    second_intent, = submit_restart("pm_second")

    expect(second_intent).to include("setup_intent_id" => "seti_2")
  end
end
