# frozen_string_literal: true

module ClientConfirmedLateSuccessHelpers
  def self.included(base)
    base.let(:seller) { create(:user) }
    base.let(:provider) { { pi_status: "succeeded", charge: {}, intent: {} } }
    base.before do
      MerchantAccount.find_or_create_by!(user_id: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id) do |merchant_account|
        merchant_account.charge_processor_alive_at = Time.current
      end
    end
  end

  def stripe_charge_hash(charge, mode)
    hash = {
      id: "ch_late_#{charge.id}", object: "charge", status: "succeeded", refunded: false, dispute: nil, amount_refunded: 0,
      amount: charge.amount_cents, currency: "usd", application_fee: nil, transfer_group: charge.id_with_prefix,
      payment_intent: charge.stripe_payment_intent_id, payment_method: "pm_late", metadata: {},
      balance_transaction: { id: "txn_late_#{charge.id}", amount: charge.amount_cents, currency: "usd", net: charge.amount_cents - 30,
                             fee: 30, fee_details: [{ type: "stripe_fee", amount: 30, currency: "usd" }] },
      payment_method_details: { type: "us_bank_account", us_bank_account: { country: "US" } },
      outcome: { risk_level: "normal" }, billing_details: { address: { postal_code: "94117" } }
    }
    case mode
    when :destination_charge
      account = charge.merchant_account.charge_processor_merchant_id
      hash.merge!(destination: account, transfer: "tr_late", transfer_data: { destination: account, amount: charge.amount_cents - charge.gumroad_amount_cents })
    when :connect_direct
      hash.merge!(application_fee: { balance_transaction: { amount: charge.gumroad_amount_cents, currency: "usd" } })
    end
    hash.merge(provider[:charge])
  end

  def stub_provider!(charge, mode)
    allow(Stripe::PaymentIntent).to receive(:retrieve) do
      Stripe::PaymentIntent.construct_from(
        id: charge.stripe_payment_intent_id, object: "payment_intent", status: provider[:pi_status],
        latest_charge: (provider[:pi_status] == "succeeded" ? "ch_late_#{charge.id}" : nil),
        transfer_group: charge.id_with_prefix, payment_method_types: %w[us_bank_account], payment_method: "pm_late",
        currency: "usd", customer: nil, metadata: {}, charges: { data: [] }, **provider[:intent]
      )
    end
    allow(Stripe::Charge).to receive(:retrieve) do |*args|
      if args.first.is_a?(Hash) && args.first[:id] == "py_late"
        seller_cents = charge.amount_cents - charge.gumroad_amount_cents
        Stripe::StripeObject.construct_from(id: "py_late", status: "succeeded", captured: true, created: Time.current.to_i,
                                            balance_transaction: { amount: seller_cents, currency: "usd", net: seller_cents })
      else
        Stripe::StripeObject.construct_from(stripe_charge_hash(charge.reload, mode))
      end
    end
    allow(Stripe::Transfer).to receive(:retrieve) do
      Stripe::StripeObject.construct_from(id: "tr_late", amount: charge.amount_cents - charge.gumroad_amount_cents,
                                          destination: charge.merchant_account.charge_processor_merchant_id, destination_payment: "py_late")
    end
    %i[cancel confirm create update capture].each do |method|
      allow(Stripe::PaymentIntent).to receive(method) { raise "unexpected provider write PaymentIntent.#{method}" }
    end
    allow(Stripe::Refund).to receive(:create) { raise "unexpected provider write Refund.create" }
  end

  def build_cart(mode: :platform_held, items: 1, gift: false, product: nil, line_item: {})
    merchant_account = case mode
                       when :destination_charge then create(:merchant_account, user: seller)
                       when :connect_direct then create(:merchant_account_stripe_connect, user: seller)
    end
    products = product ? [product] : Array.new(items) { |index| create(:product, user: seller, price_cents: 10_00 + index * 1_00) }
    params = {
      line_items: products.each_with_index.map do |cart_product, index|
        { uid: "unique-id-#{index}", permalink: cart_product.unique_permalink, perceived_price_cents: cart_product.price_cents, quantity: 1 }.merge(line_item)
      end,
      email: "buyer@example.com", cc_zipcode: "12345",
      purchase: { full_name: "Edgar Gumstein", street_address: "123 Gum Road", country: "US", state: "CA", city: "San Francisco", zip_code: "94117" },
      browser_guid: SecureRandom.uuid, ip_address: "0.0.0.0", session_id: "a107d0b7ab5ab3c1eeb7d3aaf9792977", is_mobile: false
    }
    params.merge!(is_gift: "true", giftee_email: "giftee@example.com", gift_note: "Enjoy!") if gift
    order, = Order::CreateService.new(params:).perform
    purchases = order.purchases.sort_by(&:id)
    purchases.each { _1.resolve_merchant_account_and_recompute_fees!(StripeChargeProcessor.charge_processor_id, merchant_account:) }
    charge = order.charges.create!(seller:, merchant_account: purchases.first.merchant_account,
                                   processor: StripeChargeProcessor.charge_processor_id,
                                   amount_cents: purchases.sum(&:total_transaction_cents),
                                   gumroad_amount_cents: purchases.sum(&:total_transaction_amount_for_gumroad_cents),
                                   client_confirmed: true, stripe_payment_intent_id: "pi_late_#{SecureRandom.hex(4)}")
    purchases.each do |purchase|
      purchase.update!(charge:)
      purchase.create_processor_payment_intent!(intent_id: charge.stripe_payment_intent_id)
    end
    stub_provider!(charge, mode)
    [order, charge, purchases.map(&:reload)]
  end

  def payment_intent_event(charge, type, id: "evt_#{SecureRandom.hex(4)}", attrs: {})
    {
      "id" => id, "object" => "event", "created" => 1_406_748_559, "type" => type,
      "data" => { "object" => { "object" => "payment_intent", "id" => charge.stripe_payment_intent_id,
                                "transfer_group" => charge.id_with_prefix, "latest_charge" => "ch_late_#{charge.id}",
                                "metadata" => { "purchase" => charge.reference_id_for_charge_processors } }.merge(attrs) }
    }
  end

  def deliver(charge, type, **options)
    HandleStripeEventWorker.perform_async(payment_intent_event(charge, type, **options))
    HandleStripeEventWorker.drain
  end

  def failed_event(charge, **options)
    payment_intent_event(charge, "payment_intent.payment_failed", **options,
                         attrs: { "last_payment_error" => { "code" => "generic_decline", "message" => "The bank returned a failure." } })
  end

  def fail_via_webhook(charge)
    provider[:pi_status] = "requires_payment_method"
    HandleStripeEventWorker.perform_async(failed_event(charge))
    HandleStripeEventWorker.drain
    provider[:pi_status] = "succeeded"
  end

  def ledger_cents(purchases) = BalanceTransaction.where(purchase_id: purchases.map(&:id)).sum(:issued_amount_gross_cents)
  def access_count(purchases) = UrlRedirect.where(purchase_id: purchases.map(&:id)).count
end
