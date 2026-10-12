# frozen_string_literal: true

require "spec_helper"

describe Stripe::SetupIntentsController, "resubmitting a card whose Indian e-mandate is pending" do
  let(:seller) { create(:user) }
  let(:buyer) { create(:user) }
  let(:product) { create(:subscription_product, user: seller) }
  let(:merchant_account) do
    create(:merchant_account, user: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id, charge_processor_merchant_id: nil)
  end
  let(:old_card) do
    create(
      :indian_stripe_credit_card,
      stripe_customer_id: "cus_old",
      processor_payment_method_id: "pm_old",
      stripe_fingerprint: "fp_old",
      visual: "**** **** **** 1111"
    )
  end
  let!(:subscription) do
    subscription = create(:subscription, link: product, user: buyer, credit_card: old_card)
    travel_to(2.weeks.ago) do
      create(:purchase, is_original_subscription_purchase: true, link: product, subscription:, purchaser: buyer,
                        price_cents: product.default_price_cents, credit_card: old_card)
    end
    subscription.update!(renewal_disabled_due_to_indian_card_mandate: true, indian_card_mandate_requires_reauthorization: true)
    subscription
  end
  let(:chargeable_class) do
    Struct.new(:payment_method_id, :customer_id, :stripe_setup_intent_id, :fingerprint) do
      def charge_processor_id = StripeChargeProcessor.charge_processor_id
      def prepare! = true
      def visual = "**** **** **** 4242"
      def funding_type = "credit"
      def card_type = CardType::VISA
      def expiry_month = 12
      def expiry_year = 2030
      def country = "IN"
      def requires_mandate? = true
      def stripe_payment_intent_id = nil
      def get_chargeable_for(_processor_id) = self
      def validated_stripe_mandate_id=(_mandate_id); end

      def reusable_token_for!(processor_id, _user)
        customer_id if processor_id == StripeChargeProcessor.charge_processor_id
      end
    end
  end
  let(:card_state) { { fingerprint: "fp_new" } }
  let(:minted_setup_intent_ids) { [] }
  let(:minted_setup_intents) { {} }
  let(:mandate_status) { "pending" }

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
    allow(MerchantAccount).to receive(:gumroad).with(StripeChargeProcessor.charge_processor_id).and_return(merchant_account)
    Feature.activate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)
    allow(CardParamsHelper).to receive(:check_for_errors).and_return(nil)
    allow(CardParamsHelper).to receive(:build_chargeable) do |params|
      chargeable_class.new(params[:stripe_payment_method_id], params[:stripe_customer_id].presence || "cus_#{params[:stripe_payment_method_id]}", params[:stripe_setup_intent_id], card_state[:fingerprint])
    end
    allow(ChargeProcessor).to receive(:setup_future_charges!) do |_account, chargeable, **|
      minted_setup_intent_ids << "seti_#{minted_setup_intent_ids.size + 1}"
      minted_setup_intents[minted_setup_intent_ids.last] = setup_intent_double(minted_setup_intent_ids.last, chargeable.payment_method_id, chargeable.customer_id)
    end
    allow(ChargeProcessor).to receive(:get_setup_intent) { |_account, id| minted_setup_intents.fetch(id) }
    allow(ChargeProcessor).to receive(:get_mandate) do |_account, id|
      setup_intent = minted_setup_intents.values.find { _1.mandate == id }
      Stripe::Mandate.construct_from(id:, status: mandate_status, payment_method: setup_intent.payment_method_id)
    end
    cookies.encrypted[subscription.cookie_key] = subscription.external_id
  end

  after do
    Feature.deactivate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)
  end

  # The client posts the card to /stripe/setup_intents, then submits the returned ids to update the subscription.
  def post_setup_intent(payment_method_id)
    @controller = described_class.new
    post :create, params: {
      stripe_payment_method_id: payment_method_id,
      products: [{ price: product.price_cents, permalink: product.unique_permalink, subscription_id: subscription.external_id }]
    }
    response.parsed_body
  end

  def submit_card(payment_method_id)
    setup_intent = post_setup_intent(payment_method_id)

    @controller = PurchasesController.new
    put :update_subscription, params: {
      id: subscription.external_id,
      price_id: subscription.price.external_id,
      perceived_price_cents: subscription.current_subscription_price_cents,
      perceived_upgrade_price_cents: 0,
      quantity: 1,
      stripe_payment_method_id: setup_intent["payment_method_id"] || payment_method_id,
      stripe_customer_id: setup_intent["reusable_token"],
      stripe_setup_intent_id: setup_intent["setup_intent_id"],
      card_data_handling_mode: "stripejs.0",
    }
    [setup_intent, response.parsed_body]
  end

  it "uses one setup intent and mandate when the same card is submitted twice from Manage Membership" do
    first_intent, first_update = submit_card("pm_first")
    expect(first_update).to include("success" => true)
    expect(subscription.reload.stripe_mandate_id).to eq("mandate_seti_1")
    expect(subscription).to be_renewal_disabled_due_to_indian_card_mandate

    second_intent, second_update = submit_card("pm_second")

    expect(second_update).to include("success" => true)
    expect(second_intent).to include(
      "setup_intent_id" => first_intent["setup_intent_id"],
      "reusable_token" => first_intent["reusable_token"],
      "payment_method_id" => "pm_first"
    )
    expect(minted_setup_intent_ids).to eq(["seti_1"])
    expect(subscription.reload.stripe_mandate_id).to eq("mandate_seti_1")
    expect(subscription.credit_card.stripe_setup_intent_id).to eq("seti_1")
    expect(subscription).to be_renewal_disabled_due_to_indian_card_mandate
  end

  it "mints a new setup intent when the buyer submits a different card" do
    submit_card("pm_first")

    card_state[:fingerprint] = "fp_other"
    second_intent, = submit_card("pm_second")

    expect(second_intent["setup_intent_id"]).to eq("seti_2")
    expect(minted_setup_intent_ids).to eq(%w[seti_1 seti_2])
  end

  it "mints a new setup intent when neither card has a fingerprint" do
    submit_card("pm_first")
    subscription.reload.credit_card.update_column(:stripe_fingerprint, nil)
    card_state[:fingerprint] = nil

    second_intent, = submit_card("pm_second")

    expect(second_intent["setup_intent_id"]).to eq("seti_2")
    expect(second_intent).not_to have_key("payment_method_id")
    expect(minted_setup_intent_ids).to eq(%w[seti_1 seti_2])
  end

  it "mints a new setup intent and uses the entered card once the pending mandate has become active" do
    submit_card("pm_first")
    allow(ChargeProcessor).to receive(:get_mandate).and_return(
      Stripe::Mandate.construct_from(id: "mandate_seti_1", status: "active", payment_method: "pm_first")
    )

    second_intent, = submit_card("pm_second")

    expect(second_intent).to include("setup_intent_id" => "seti_2", "reusable_token" => "cus_pm_second")
    expect(second_intent).not_to have_key("payment_method_id")
    expect(minted_setup_intent_ids).to eq(%w[seti_1 seti_2])
  end

  it "mints a new setup intent once the pending mandate has become inactive" do
    submit_card("pm_first")
    allow(ChargeProcessor).to receive(:get_mandate).and_return(
      Stripe::Mandate.construct_from(id: "mandate_seti_1", status: "inactive", payment_method: "pm_first")
    )

    second_intent, = submit_card("pm_second")

    expect(second_intent["setup_intent_id"]).to eq("seti_2")
  end

  describe "when looking up the stored pending setup intent fails" do
    let(:stored_mandate_id) { "mandate_seti_1" }

    def fail_stored_lookup(setup_intent_error: nil, mandate_error: nil, mandate_status: nil)
      allow(ChargeProcessor).to receive(:get_setup_intent) do |_account, id|
        raise setup_intent_error if setup_intent_error && id == "seti_1"

        minted_setup_intents.fetch(id)
      end
      allow(ChargeProcessor).to receive(:get_mandate) do |_account, id|
        raise mandate_error if mandate_error && id == stored_mandate_id

        setup_intent = minted_setup_intents.values.find { _1.mandate == id }
        Stripe::Mandate.construct_from(id:, status: (id == stored_mandate_id && mandate_status) || self.mandate_status, payment_method: setup_intent.payment_method_id)
      end
    end

    def expect_new_setup_intent_instead_of_blocking
      second_intent, second_update = submit_card("pm_second")

      expect(response).to have_http_status(:ok)
      expect(second_intent).to include("success" => true, "setup_intent_id" => "seti_2")
      expect(second_update).to include("success" => true)
      expect(minted_setup_intent_ids).to eq(%w[seti_1 seti_2])
      expect(subscription.reload.credit_card.stripe_setup_intent_id).to eq("seti_2")
      expect(subscription).to be_renewal_disabled_due_to_indian_card_mandate
    end

    before { submit_card("pm_first") }

    it "mints a new setup intent when the stored setup intent id is stale" do
      fail_stored_lookup(setup_intent_error: ChargeProcessorInvalidRequestError.new("No such setup_intent: seti_1"))
      expect(ErrorNotifier).not_to receive(:notify)

      expect_new_setup_intent_instead_of_blocking
    end

    it "mints a new setup intent when the stored mandate is missing at Stripe" do
      fail_stored_lookup(mandate_error: ChargeProcessorInvalidRequestError.new("No such mandate: mandate_seti_1"))
      expect(ErrorNotifier).not_to receive(:notify)

      expect_new_setup_intent_instead_of_blocking
    end

    def expect_retryable_failure_without_a_second_setup_intent
      post_setup_intent("pm_second")

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body).to eq("success" => false, "error_message" => Stripe::SetupIntentsController::PROVIDER_UNAVAILABLE_MESSAGE)
      expect(minted_setup_intent_ids).to eq(%w[seti_1])
      expect(subscription.reload.credit_card.stripe_setup_intent_id).to eq("seti_1")
      expect(subscription.credit_card.processor_payment_method_id).to eq("pm_first")
    end

    it "returns the retryable provider-unavailable response without minting when the mandate lookup is unavailable" do
      fail_stored_lookup(mandate_error: ChargeProcessorUnavailableError.new("stripe down"))
      expect(ErrorNotifier).to receive(:notify).with(instance_of(ChargeProcessorUnavailableError), subscription: subscription.external_id)

      expect_retryable_failure_without_a_second_setup_intent
    end

    it "returns the retryable provider-unavailable response without minting when the setup intent lookup is unavailable" do
      fail_stored_lookup(setup_intent_error: ChargeProcessorUnavailableError.new("stripe down"))
      expect(ErrorNotifier).to receive(:notify).with(instance_of(ChargeProcessorUnavailableError), subscription: subscription.external_id)

      expect_retryable_failure_without_a_second_setup_intent
    end

    it "returns the retryable provider-unavailable response without minting when Stripe rate limits the lookup" do
      fail_stored_lookup(mandate_error: ChargeProcessorErrorRateLimit.new)
      expect(ErrorNotifier).to receive(:notify).with(instance_of(ChargeProcessorErrorRateLimit), subscription: subscription.external_id)

      expect_retryable_failure_without_a_second_setup_intent
    end

    it "returns the retryable provider-unavailable response without minting when Stripe returns an unknown mandate status" do
      fail_stored_lookup(mandate_status: "surprising")
      expect(ErrorNotifier).to receive(:notify).with(instance_of(RuntimeError), subscription: subscription.external_id)

      expect_retryable_failure_without_a_second_setup_intent
    end

    it "reuses the stored setup intent on the repeat submission once the provider recovers" do
      fail_stored_lookup(mandate_error: ChargeProcessorUnavailableError.new("stripe down"))
      post_setup_intent("pm_second")
      expect(response).to have_http_status(:service_unavailable)
      fail_stored_lookup

      second_intent, second_update = submit_card("pm_second")

      expect(response).to have_http_status(:ok)
      expect(second_intent).to include("success" => true, "setup_intent_id" => "seti_1", "payment_method_id" => "pm_first")
      expect(second_update).to include("success" => true)
      expect(minted_setup_intent_ids).to eq(%w[seti_1])
      expect(subscription.reload.credit_card.stripe_setup_intent_id).to eq("seti_1")
    end
  end
end
