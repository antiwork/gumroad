# frozen_string_literal: true

require "spec_helper"

describe "Client-confirmed PaymentIntent webhook lifecycle", :vcr do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 10_00) }
  let(:line_item) { { uid: "unique-id-0", permalink: product.unique_permalink, perceived_price_cents: product.price_cents, quantity: 1 } }
  let(:common_params) do
    {
      email: "buyer@example.com",
      cc_zipcode: "12345",
      purchase: {
        full_name: "Edgar Gumstein", street_address: "123 Gum Road",
        country: "US", state: "CA", city: "San Francisco", zip_code: "94117"
      },
      browser_guid: SecureRandom.uuid,
      ip_address: "0.0.0.0",
      session_id: "a107d0b7ab5ab3c1eeb7d3aaf9792977",
      is_mobile: false,
    }
  end

  before do
    MerchantAccount.find_or_create_by!(user_id: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id) do |ma|
      ma.charge_processor_alive_at = Time.current
    end
  end

  def build_client_confirmed_order(line_items: [line_item])
    params = { line_items: }.merge(common_params)
    order, = Order::CreateService.new(params:).perform
    purchases = order.purchases.to_a
    purchases.each { _1.resolve_merchant_account_and_recompute_fees!(StripeChargeProcessor.charge_processor_id) }
    merchant_account = purchases.first.merchant_account
    amount_cents = purchases.sum(&:total_transaction_cents)
    gumroad_amount_cents = purchases.sum(&:total_transaction_amount_for_gumroad_cents)

    charge = order.charges.create!(seller:, merchant_account:, processor: merchant_account.charge_processor_id,
                                   amount_cents:, gumroad_amount_cents:, client_confirmed: true)
    purchases.each { _1.update!(charge:) }

    charge_intent = StripeDeferredPaymentIntent.create(
      merchant_account:, amount_cents:, amount_for_gumroad_cents: gumroad_amount_cents,
      reference: "#{Charge::COMBINED_CHARGE_PREFIX}#{charge.external_id}",
      description: "Gumroad Charge #{charge.external_id}",
      statement_description: seller.name_or_username,
      transfer_group: charge.id_with_prefix,
      idempotency_key: "deferred_intent_test_#{SecureRandom.hex}",
      payment_method_types: Checkout::PaymentMethodResolver::LAUNCHED_PAYMENT_METHOD_TYPES,
      currency: Checkout::StripePaymentPresenter::CLIENT_CONFIRM_CURRENCY
    )
    charge.update!(stripe_payment_intent_id: charge_intent.id)
    purchases.each { _1.create_processor_payment_intent!(intent_id: charge_intent.id) }
    [order, charge]
  end

  def payment_intent_event(type, charge, event_id:, account: nil, object_attrs: {})
    {
      "id" => event_id,
      "object" => "event",
      "created" => 1_406_748_559,
      "type" => type,
      "account" => account,
      "data" => {
        "object" => {
          "object" => "payment_intent",
          "id" => charge.stripe_payment_intent_id,
          "transfer_group" => charge.id_with_prefix,
          "metadata" => { "purchase" => charge.reference_id_for_charge_processors }
        }.merge(object_attrs)
      }
    }.compact
  end

  def deliver_webhook(event)
    HandleStripeEventWorker.perform_async(event)
    HandleStripeEventWorker.drain
  end

  context "payment_intent.succeeded for a purchase whose browser never returned" do
    it "finalizes the order via the webhook, exactly once across replays" do
      order, charge = build_client_confirmed_order
      Stripe::PaymentIntent.confirm(charge.stripe_payment_intent_id, { payment_method: "pm_card_visa" })
      purchase = order.purchases.first
      event = payment_intent_event("payment_intent.succeeded", charge, event_id: "evt_succeeded_1")

      expect do
        deliver_webhook(event)
      end.to change { ActivateIntegrationsWorker.jobs.size }.by(1)
        .and change { SendChargeReceiptJob.jobs.size }.by(1)

      expect(purchase.reload).to be_successful
      expect(purchase.stripe_transaction_id).to be_present
      expect(charge.reload.processor_transaction_id).to be_present
      expect(ProcessedStripeEvent.processed?("evt_succeeded_1")).to be(true)
      succeeded_at = purchase.succeeded_at

      expect do
        deliver_webhook(event)
      end.not_to change { [ActivateIntegrationsWorker.jobs.size, SendChargeReceiptJob.jobs.size] }

      expect(purchase.reload.succeeded_at).to eq(succeeded_at)
    end
  end

  context "when the browser finalized inline before the webhook arrives" do
    it "fulfills exactly once across both triggers" do
      order, charge = build_client_confirmed_order
      Stripe::PaymentIntent.confirm(charge.stripe_payment_intent_id, { payment_method: "pm_card_visa" })
      purchase = order.purchases.first

      expect do
        Order::FinalizeConfirmedChargeService.new(order:).perform
      end.to change { ActivateIntegrationsWorker.jobs.size }.by(1)
      expect(purchase.reload).to be_successful

      expect do
        deliver_webhook(payment_intent_event("payment_intent.succeeded", charge, event_id: "evt_after_inline"))
      end.not_to change { ActivateIntegrationsWorker.jobs.size }
      expect(purchase.reload).to be_successful
    end
  end

  context "when finalize fails transiently after payment_intent.succeeded" do
    it "leaves the event unrecorded so the Sidekiq retry can finalize" do
      charge = create(:charge, seller:, client_confirmed: true, stripe_payment_intent_id: "pi_retry")
      create(:purchase_in_progress, link: product, seller:).tap { charge.purchases << _1 }
      event = payment_intent_event("payment_intent.succeeded", charge, event_id: "evt_retry")

      finalize = instance_double(Order::FinalizeConfirmedChargeService)
      allow(Order::FinalizeConfirmedChargeService).to receive(:new).and_return(finalize)
      allow(finalize).to receive(:perform).and_raise(Stripe::APIConnectionError.new("transient"))

      expect { deliver_webhook(event) }.to raise_error(Stripe::APIConnectionError)
      expect(ProcessedStripeEvent.processed?("evt_retry")).to be(false)

      allow(finalize).to receive(:perform).and_return({})
      deliver_webhook(event)

      expect(finalize).to have_received(:perform).twice
      expect(ProcessedStripeEvent.processed?("evt_retry")).to be(true)
    end
  end

  context "when payment_intent.succeeded arrives before a late payment_intent.processing" do
    it "keeps the purchase successful and does not regress it to in_progress" do
      order, charge = build_client_confirmed_order
      Stripe::PaymentIntent.confirm(charge.stripe_payment_intent_id, { payment_method: "pm_card_visa" })
      purchase = order.purchases.first

      deliver_webhook(payment_intent_event("payment_intent.succeeded", charge, event_id: "evt_ooo_succeeded"))
      expect(purchase.reload).to be_successful

      deliver_webhook(payment_intent_event("payment_intent.processing", charge, event_id: "evt_ooo_processing"))
      expect(purchase.reload).to be_successful
    end
  end

  context "payment_intent.processing then payment_intent.payment_failed for a client-confirmed charge" do
    it "keeps the purchase in progress while processing, then fails it to a resubmittable state on payment_failed" do
      seller = create(:user)
      charge = create(:charge, seller:, client_confirmed: true, stripe_payment_intent_id: "pi_proc_fail")
      purchase = create(:purchase_in_progress, link: create(:product, user: seller), seller:)
      charge.purchases << purchase

      deliver_webhook(payment_intent_event("payment_intent.processing", charge, event_id: "evt_pf_processing"))
      expect(purchase.reload).to be_in_progress
      expect(ProcessedStripeEvent.processed?("evt_pf_processing")).to be(true)

      # A delayed-notification method (ACH) whose debit later fails must return the buyer to a
      # resubmittable cart, so the client-confirmed charge's in_progress purchases are marked failed.
      deliver_webhook(payment_intent_event("payment_intent.payment_failed", charge, event_id: "evt_pf_failed"))
      expect(purchase.reload).to be_failed
      # payment_failed is deliberately NOT recorded in ProcessedStripeEvent: recording is scoped to
      # PAYMENT_INTENT_LIFECYCLE_EVENTS (processing/succeeded), where it gates exactly-once
      # fulfillment. The failed path's idempotency is the in_progress? guard in the handler.
      expect(ProcessedStripeEvent.processed?("evt_pf_failed")).to be(false)
    end

    it "is a no-op when the purchase already reached a terminal state (re-delivered payment_failed)" do
      seller = create(:user)
      charge = create(:charge, seller:, client_confirmed: true, stripe_payment_intent_id: "pi_fail_terminal")
      purchase = create(:purchase, link: create(:product, user: seller), seller:)
      charge.purchases << purchase
      expect(purchase).to be_successful

      deliver_webhook(payment_intent_event("payment_intent.payment_failed", charge, event_id: "evt_pf_terminal"))
      expect(purchase.reload).to be_successful
      # Not recorded (see above) — a re-delivery is safe because the in_progress? guard skips
      # terminal purchases, not because the event is deduplicated.
      expect(ProcessedStripeEvent.processed?("evt_pf_terminal")).to be(false)
    end

    it "persists the decline reason from last_payment_error onto the failed purchase" do
      seller = create(:user)
      charge = create(:charge, seller:, client_confirmed: true, stripe_payment_intent_id: "pi_async_decline")
      purchase = create(:purchase_in_progress, link: create(:product, user: seller), seller:)
      charge.purchases << purchase

      # A Cash App Pay decline never raises Stripe::CardError at confirm time — the reason only
      # arrives via this webhook's last_payment_error.
      deliver_webhook(payment_intent_event(
                        "payment_intent.payment_failed", charge, event_id: "evt_async_decline",
                                                                 object_attrs: {
                                                                   "last_payment_error" => {
                                                                     "code" => "payment_method_provider_decline",
                                                                     "decline_code" => "insufficient_funds",
                                                                     "message" => "Cash App Pay has declined the payment.",
                                                                     "type" => "card_error"
                                                                   }
                                                                 }
                      ))

      expect(purchase.reload).to be_failed
      expect(purchase.stripe_error_code).to eq("payment_method_provider_decline_insufficient_funds")
    end

    it "still fails the purchase when the webhook carries no last_payment_error" do
      seller = create(:user)
      charge = create(:charge, seller:, client_confirmed: true, stripe_payment_intent_id: "pi_no_lpe")
      purchase = create(:purchase_in_progress, link: create(:product, user: seller), seller:)
      charge.purchases << purchase

      deliver_webhook(payment_intent_event("payment_intent.payment_failed", charge, event_id: "evt_no_lpe"))

      expect(purchase.reload).to be_failed
      expect(purchase.stripe_error_code).to be_nil
    end
  end

  context "payment_intent.succeeded for a multi-item combined charge" do
    it "fulfills every purchase in the single-seller charge" do
      second_product = create(:product, user: seller, price_cents: 5_00)
      second_line_item = { uid: "unique-id-1", permalink: second_product.unique_permalink, perceived_price_cents: second_product.price_cents, quantity: 1 }
      order, charge = build_client_confirmed_order(line_items: [line_item, second_line_item])
      Stripe::PaymentIntent.confirm(charge.stripe_payment_intent_id, { payment_method: "pm_card_visa" })

      expect do
        deliver_webhook(payment_intent_event("payment_intent.succeeded", charge, event_id: "evt_combined"))
      end.to change { ActivateIntegrationsWorker.jobs.size }.by(2)

      expect(order.purchases.reload.count).to eq(2)
      expect(order.purchases.all?(&:successful?)).to be(true)
    end
  end

  context "payment_intent.processing" do
    it "leaves the purchase in progress with no fulfillment and records the event" do
      order, charge = build_client_confirmed_order
      purchase = order.purchases.first
      event = payment_intent_event("payment_intent.processing", charge, event_id: "evt_processing_1")

      expect do
        deliver_webhook(event)
      end.not_to change { ActivateIntegrationsWorker.jobs.size }

      expect(purchase.reload).to be_in_progress
      expect(purchase.successful?).to be(false)
      expect(purchase.stripe_status).to eq("payment_intent.processing")
      expect(ProcessedStripeEvent.processed?("evt_processing_1")).to be(true)
    end
  end

  context "charge.succeeded for a client-confirmed charge" do
    it "does not finalize it (payment_intent.succeeded is the sole source of truth)" do
      charge = create(:charge, seller:, client_confirmed: true, stripe_payment_intent_id: "pi_lane_b")
      purchase = create(:purchase_in_progress, link: product, seller:).tap { charge.purchases << _1 }
      event = {
        "id" => "evt_charge_succeeded",
        "object" => "event",
        "created" => 1_406_748_559,
        "type" => "charge.succeeded",
        "data" => { "object" => { "object" => "charge", "id" => "ch_x", "payment_intent" => "pi_lane_b", "transfer_group" => charge.id_with_prefix, "metadata" => {} } }
      }

      expect do
        deliver_webhook(event)
      end.not_to change { ActivateIntegrationsWorker.jobs.size }

      expect(purchase.reload).to be_in_progress
    end
  end

  context "when the PaymentIntent is not a client-confirmed charge" do
    it "ignores a server-confirmed charge and records nothing" do
      order, charge = build_client_confirmed_order
      charge.update!(client_confirmed: false)
      purchase = order.purchases.first

      deliver_webhook(payment_intent_event("payment_intent.succeeded", charge, event_id: "evt_lane_a"))

      expect(purchase.reload).to be_in_progress
      expect(ProcessedStripeEvent.processed?("evt_lane_a")).to be(false)
    end

    it "ignores a PaymentIntent with no matching charge" do
      event = {
        "id" => "evt_no_match",
        "object" => "event",
        "created" => 1_406_748_559,
        "type" => "payment_intent.succeeded",
        "data" => { "object" => { "object" => "payment_intent", "id" => "pi_unknown", "transfer_group" => "CH-999999999", "metadata" => {} } }
      }

      deliver_webhook(event)

      expect(ProcessedStripeEvent.processed?("evt_no_match")).to be(false)
    end
  end

  context "for a direct-charge (connected account) client-confirmed charge" do
    let(:seller) { create(:user, check_merchant_account_is_linked: true) }
    let!(:connect_account) { create(:merchant_account_stripe_connect, user: seller) }

    def confirm_on_connected_account(charge)
      Stripe::PaymentIntent.confirm(
        charge.stripe_payment_intent_id,
        { payment_method: "pm_card_visa" },
        { stripe_account: connect_account.charge_processor_merchant_id }
      )
    end

    it "finalizes the order via the connect-endpoint webhook when the browser never returned" do
      order, charge = build_client_confirmed_order
      expect(charge.merchant_account).to eq(connect_account)
      confirm_on_connected_account(charge)
      purchase = order.purchases.first
      event = payment_intent_event("payment_intent.succeeded", charge,
                                   event_id: "evt_connect_succeeded_1",
                                   account: connect_account.charge_processor_merchant_id)

      expect do
        deliver_webhook(event)
      end.to change { ActivateIntegrationsWorker.jobs.size }.by(1)
        .and change { SendChargeReceiptJob.jobs.size }.by(1)

      expect(purchase.reload).to be_successful
      expect(purchase.stripe_transaction_id).to be_present
      expect(purchase.merchant_account).to eq(connect_account)
      expect(ProcessedStripeEvent.processed?("evt_connect_succeeded_1")).to be(true)

      # Replay is a no-op.
      expect do
        deliver_webhook(event)
      end.not_to change { ActivateIntegrationsWorker.jobs.size }
    end

    it "keeps the purchase in progress on payment_intent.processing and records the event" do
      order, charge = build_client_confirmed_order
      purchase = order.purchases.first
      event = payment_intent_event("payment_intent.processing", charge,
                                   event_id: "evt_connect_processing_1",
                                   account: connect_account.charge_processor_merchant_id)

      expect do
        deliver_webhook(event)
      end.not_to change { ActivateIntegrationsWorker.jobs.size }

      expect(purchase.reload).to be_in_progress
      expect(purchase.stripe_status).to eq("payment_intent.processing")
      expect(ProcessedStripeEvent.processed?("evt_connect_processing_1")).to be(true)
    end

    it "ignores an unrelated connected-account PaymentIntent (a seller's non-Gumroad sale) without recording or notifying" do
      # Connected accounts deliver payment_intent.* for every charge they process, including ones
      # Gumroad never created. Those carry no Gumroad charge reference and must be a cheap no-op.
      event = {
        "id" => "evt_connect_unrelated",
        "object" => "event",
        "created" => 1_406_748_559,
        "type" => "payment_intent.succeeded",
        "account" => connect_account.charge_processor_merchant_id,
        "data" => { "object" => { "object" => "payment_intent", "id" => "pi_not_ours", "transfer_group" => nil, "metadata" => {} } }
      }

      expect(ErrorNotifier).not_to receive(:notify)

      expect do
        deliver_webhook(event)
      end.not_to change { ActivateIntegrationsWorker.jobs.size }

      expect(ProcessedStripeEvent.processed?("evt_connect_unrelated")).to be(false)
    end
  end
end
