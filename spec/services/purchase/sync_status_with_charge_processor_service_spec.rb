# frozen_string_literal: false

describe Purchase::SyncStatusWithChargeProcessorService, :vcr do
  before do
    MerchantAccount.find_or_create_by!(user_id: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id) do |ma|
      ma.charge_processor_alive_at = Time.current
    end
    @initial_balance = 200
    @seller = create(:user, unpaid_balance_cents: @initial_balance)
    @product = create(:product, user: @seller)
  end

  it "marks a free purchase as successful and returns true" do
    offer_code = create(:offer_code, products: [@product], amount_cents: 100)
    purchase = create(:free_purchase, link: @product, purchase_state: "in_progress", offer_code:)
    purchase.process!

    expect(purchase.reload.in_progress?).to be(true)
    expect(purchase.free_purchase?).to be(true)
    expect(purchase.stripe_transaction_id).to be(nil)

    expect(Purchase::SyncStatusWithChargeProcessorService.new(purchase).perform).to be(true)

    expect(purchase.reload.successful?).to be(true)
  end

  it "marks a free gift purchase as successful and marks the associated giftee purchase as successful too in case of a successful gift purchase and returns true" do
    gift = create(:gift)
    offer_code = create(:offer_code, products: [gift.link], amount_cents: 100)
    purchase_given = build(:free_purchase, link: gift.link, gift_given: gift, is_gift_sender_purchase: true, offer_code:, purchase_state: "in_progress")
    purchase_received = create(:free_purchase, link: gift.link, gift_received: purchase_given.gift, is_gift_receiver_purchase: true, purchase_state: "in_progress")
    purchase_given.process!

    expect(purchase_given.reload.in_progress?).to be(true)
    expect(purchase_given.free_purchase?).to be(true)
    expect(purchase_given.stripe_transaction_id).to be(nil)

    expect(Purchase::SyncStatusWithChargeProcessorService.new(purchase_given).perform).to be(true)

    expect(purchase_given.reload.successful?).to be(true)
    expect(purchase_received.reload.gift_receiver_purchase_successful?).to be(true)
    expect(purchase_given.gift.successful?).to be(true)
  end

  it "marks a free purchase for a subscription as succcessful and creates the subscription and returns true" do
    product = create(:product, :is_subscription, user: @seller)
    offer_code = create(:offer_code, products: [product], amount_cents: 100)
    purchase = create(:free_purchase, link: product, purchase_state: "in_progress", offer_code:, price: product.default_price)
    purchase.process!

    expect(purchase.reload.in_progress?).to be(true)
    expect(purchase.free_purchase?).to be(true)
    expect(purchase.stripe_transaction_id).to be(nil)

    expect(Purchase::SyncStatusWithChargeProcessorService.new(purchase).perform).to be(true)

    expect(purchase.reload.successful?).to be(true)
    expect(purchase.subscription.alive?).to be(true)
  end

  it "marks a free purchase for a subscription as successful and does not create a subscription if one is already present and returns true" do
    product = create(:product, :is_subscription, user: @seller)
    offer_code = create(:offer_code, products: [product], amount_cents: 100)
    purchase = create(:free_purchase, link: product, purchase_state: "in_progress", offer_code:, price: product.default_price)
    purchase.process!
    subscription = create(:subscription, link: product)
    subscription.purchases << purchase

    expect(purchase.reload.in_progress?).to be(true)
    expect(purchase.free_purchase?).to be(true)
    expect(purchase.stripe_transaction_id).to be(nil)
    expect(purchase.subscription).to eq(subscription)

    expect(Purchase::SyncStatusWithChargeProcessorService.new(purchase).perform).to be(true)

    expect(purchase.reload.successful?).to be(true)
    expect(purchase.subscription).to eq(subscription)
    expect(purchase.subscription.alive?).to be(true)
  end

  it "marks the purchase as successful and returns true if purchase's charge was successful" do
    purchase = create(:purchase, link: @product, purchase_state: "in_progress", chargeable: create(:chargeable))
    purchase.process!
    expect(purchase.reload.in_progress?).to be(true)
    expect(purchase.stripe_transaction_id).not_to be(nil)
    expect(@seller.reload.unpaid_balance_cents).to eq(@initial_balance)

    expect(Purchase::SyncStatusWithChargeProcessorService.new(purchase).perform).to be(true)

    expect(purchase.reload.successful?).to be(true)
    expect(@seller.reload.unpaid_balance_cents).to eq(@initial_balance + purchase.payment_cents)
  end

  it "marks the purchase that is part of a combined charge as successful and returns true" do
    product = create(:product, user: @seller, price_cents: 10_00)
    params = {
      email: "buyer@gumroad.com",
      cc_zipcode: "12345",
      purchase: {
        full_name: "Edgar Gumstein",
        zip_code: "94117"
      },
      browser_guid: SecureRandom.uuid,
      ip_address: "0.0.0.0",
      session_id: "a107d0b7ab5ab3c1eeb7d3aaf9792977",
      is_mobile: false,
      line_items: [
        {
          uid: "unique-id-0",
          permalink: product.unique_permalink,
          perceived_price_cents: product.price_cents,
          quantity: 1
        }
      ]
    }.merge(StripePaymentMethodHelper.success.to_stripejs_params)
    allow_any_instance_of(Charge).to receive(:id).and_return(1234567)

    order, _ = Order::CreateService.new(params:).perform
    Order::ChargeService.new(order:, params:).perform
    purchase = order.purchases.last
    purchase.update!(purchase_state: "in_progress", stripe_transaction_id: nil)

    expect(purchase.reload.in_progress?).to be(true)
    expect(purchase.stripe_transaction_id).to be(nil)

    expect(Purchase::SyncStatusWithChargeProcessorService.new(purchase).perform).to be(true)

    expect(purchase.reload.successful?).to be(true)
    expect(purchase.stripe_transaction_id).to be_present
    expect(purchase.charge.processor_transaction_id).to be_present
    expect(@seller.reload.unpaid_balance_cents).to eq(@initial_balance + purchase.payment_cents)
  end

  it "delegates client-confirmed recovery to the PaymentIntent finalizer" do
    order = create(:order)
    charge = create(:charge, order:, seller: @seller, client_confirmed: true,
                             stripe_payment_intent_id: "pi_client_confirmed_recovery")
    purchase = create(:purchase_in_progress, link: @product)
    charge.purchases << purchase
    finalizer = instance_double(Order::FinalizeConfirmedChargeService, charge_intent: nil)

    expect(Order::FinalizeConfirmedChargeService).to receive(:new).with(order:, charge:).and_return(finalizer)
    expect(finalizer).to receive(:perform) { purchase.update!(purchase_state: "successful") }
    expect(ChargeProcessor).not_to receive(:get_or_search_charge)
    expect(purchase).to receive(:with_lock).and_call_original

    expect(described_class.new(purchase, mark_as_failed: true).perform).to be(true)
    expect(purchase.reload).to be_successful
  end

  it "finalizes a combined-charge purchase whose destination payment Stripe never credited, booking zero in the account's currency" do
    # gumroad-private#1608 end to end: the seller's cut is our one-subunit floor in the charge's
    # currency, which rounds below one subunit of the destination account's currency, so Stripe
    # accepts the destination payment and never produces a balance transaction for it. Nothing
    # here is stubbed below the processor's HTTP calls — the "CH-" transfer_group must really
    # resolve to the Charge's merchant account for the currency label to be right.
    merchant_account = create(:merchant_account, user: @seller, currency: Currency::EUR,
                                                 charge_processor_merchant_id: "acct_1608")
    charge = create(:charge, seller: @seller, merchant_account:, processor_transaction_id: "ch_1608")
    purchase = create(:purchase, link: @product, seller: @seller, purchase_state: "in_progress",
                                 charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                 merchant_account:, stripe_transaction_id: "ch_1608")
    charge.purchases << purchase

    stripe_charge = Stripe::Charge.construct_from(
      id: "ch_1608", status: "succeeded", refunded: false, dispute: nil,
      currency: "usd", amount: purchase.total_transaction_cents,
      destination: "acct_1608", transfer: "tr_1608",
      transfer_data: { destination: "acct_1608", amount: 1 },
      transfer_group: charge.id_with_prefix,
      balance_transaction: Stripe::BalanceTransaction.construct_from(
        id: "txn_1608", currency: "usd", amount: purchase.total_transaction_cents,
        net: purchase.total_transaction_cents - 30, status: "available",
        fee_details: [{ type: "stripe_fee", currency: "usd", amount: 30 }]
      ),
      application_fee: nil, payment_method: "pm_1608", payment_method_details: nil, outcome: nil
    )
    allow(Stripe::Charge).to receive(:retrieve).with(hash_including(id: "ch_1608"), any_args).and_return(stripe_charge)
    allow(Stripe::Charge).to receive(:retrieve).with(hash_including(id: "py_1608"), any_args)
      .and_return(Stripe::Charge.construct_from(id: "py_1608", status: "succeeded", captured: true,
                                                currency: "usd", amount: 1, balance_transaction: nil,
                                                created: 48.hours.ago.to_i))
    allow(Stripe::Transfer).to receive(:retrieve)
      .and_return(Stripe::Transfer.construct_from(id: "tr_1608", amount: 1, currency: "usd",
                                                  destination: "acct_1608", destination_payment: "py_1608"))

    expect(Purchase::SyncStatusWithChargeProcessorService.new(purchase, require_final_charge_status: true).perform).to be(true)

    expect(purchase.reload).to be_successful
    seller_balance_transaction = purchase.balance_transactions.find_by(user: @seller)
    expect(seller_balance_transaction).to be_present
    # The account received nothing, recorded in ITS currency — not the transfer's usd cents.
    expect(seller_balance_transaction.holding_amount_currency).to eq(Currency::EUR)
    expect(seller_balance_transaction.holding_amount_gross_cents).to eq(0)
    expect(seller_balance_transaction.holding_amount_net_cents).to eq(0)
    # And the balance it lands on stays payable, which a usd label on a eur account would break.
    expect(StripePayoutProcessor.is_balance_payable(seller_balance_transaction.balance)).to be(true)
  end

  it "leaves a seller-held Stripe purchase in progress while settlement data is missing" do
    merchant_account = create(:merchant_account, user: @seller, currency: Currency::EUR,
                                                 charge_processor_merchant_id: "acct_missing_settlement")
    charge = create(:charge, seller: @seller, merchant_account:, processor_transaction_id: "ch_missing_settlement")
    purchase = create(:purchase_in_progress, link: @product, seller: @seller,
                                             charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                             merchant_account:, stripe_transaction_id: "ch_missing_settlement",
                                             flow_of_funds: nil)
    charge.purchases << purchase
    processor_charge = Struct.new(:id, :status, :refunded, :disputed, :flow_of_funds) do
      def refunded? = refunded
    end.new("ch_missing_settlement", "succeeded", false, false, nil)
    allow(ChargeProcessor).to receive(:get_or_search_charge).with(purchase).and_return(processor_charge)
    allow(ChargeProcessor).to receive(:charge_processor_success_statuses).and_return(["succeeded"])
    expect(Purchase::MarkSuccessfulService).not_to receive(:new)

    expect(described_class.new(purchase, require_final_charge_status: true).perform).to be(false)

    expect(purchase.reload).to be_in_progress
    expect(purchase.flow_of_funds).to be_nil
    expect(purchase.balance_transactions).to be_empty
  end

  it "repairs a nil purchase merchant account from the charge before the processor lookup and stays in progress" do
    merchant_account = create(:merchant_account_stripe_connect, user: @seller, currency: Currency::EUR)
    charge = create(:charge, seller: @seller, merchant_account:, processor_transaction_id: "ch_missing_ma")
    purchase = create(:purchase_in_progress, link: @product, seller: @seller,
                                             charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                             merchant_account: nil, stripe_transaction_id: "ch_missing_ma",
                                             flow_of_funds: nil)
    charge.purchases << purchase
    expect(purchase.reload.merchant_account_id).to be_nil
    processor_charge = Struct.new(:id, :status, :refunded, :disputed, :flow_of_funds) do
      def refunded? = refunded
    end.new("ch_missing_ma", "succeeded", false, false, nil)
    # A platform-scoped retrieve raises for a seller's direct charge, so the lookup must
    # receive the charge's seller account; get_or_search_charge itself stays unstubbed.
    expect(ChargeProcessor).to receive(:get_charge)
      .with(StripeChargeProcessor.charge_processor_id, "ch_missing_ma", merchant_account:)
      .and_return(processor_charge)
    allow(ChargeProcessor).to receive(:charge_processor_success_statuses).and_return(["succeeded"])
    expect(Purchase::MarkSuccessfulService).not_to receive(:new)

    expect(described_class.new(purchase, require_final_charge_status: true).perform).to be(false)

    expect(purchase.reload).to be_in_progress
    expect(purchase.flow_of_funds).to be_nil
    expect(purchase.merchant_account).to eq(merchant_account)
  end

  it "repairs a stale Gumroad purchase merchant account from the charge before the processor lookup" do
    seller_account = create(:merchant_account_stripe_connect, user: @seller, currency: Currency::EUR)
    gumroad_account = create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_gumroad_stale")
    charge = create(:charge, seller: @seller, merchant_account: seller_account, processor_transaction_id: "ch_stale_ma")
    purchase = create(:purchase_in_progress, link: @product, seller: @seller,
                                             charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                             merchant_account: gumroad_account, stripe_transaction_id: "ch_stale_ma",
                                             flow_of_funds: nil)
    charge.purchases << purchase
    processor_charge = Struct.new(:id, :status, :refunded, :disputed, :flow_of_funds) do
      def refunded? = refunded
    end.new("ch_stale_ma", "succeeded", false, false, nil)
    expect(ChargeProcessor).to receive(:get_charge)
      .with(StripeChargeProcessor.charge_processor_id, "ch_stale_ma", merchant_account: seller_account)
      .and_return(processor_charge)
    allow(ChargeProcessor).to receive(:charge_processor_success_statuses).and_return(["succeeded"])
    expect(Purchase::MarkSuccessfulService).not_to receive(:new)

    expect(described_class.new(purchase, require_final_charge_status: true).perform).to be(false)

    expect(purchase.reload).to be_in_progress
    expect(purchase.merchant_account).to eq(seller_account)
  end

  it "uses subscription success handling for seller-held Stripe recurring purchases once settlement data exists" do
    product = create(:product, :is_subscription, user: @seller)
    subscription = create(:subscription, link: product)
    create(:membership_purchase, link: product, seller: @seller, subscription:)
    merchant_account = create(:merchant_account, user: @seller, currency: Currency::EUR,
                                                 charge_processor_merchant_id: "acct_recurring_settled")
    charge = create(:charge, seller: @seller, merchant_account:, processor_transaction_id: "ch_recurring_settled")
    purchase = create(:recurring_membership_purchase, link: product, seller: @seller, subscription:,
                                                      purchase_state: "in_progress",
                                                      charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                                      merchant_account:, stripe_transaction_id: "ch_recurring_settled",
                                                      flow_of_funds: nil)
    charge.purchases << purchase
    processor_charge = Struct.new(:id, :status, :refunded, :disputed, :flow_of_funds) do
      def refunded? = refunded
    end.new("ch_recurring_settled", "succeeded", false, false,
            FlowOfFunds.build_simple_flow_of_funds(Currency::EUR, purchase.total_transaction_cents))
    allow(ChargeProcessor).to receive(:get_or_search_charge).with(purchase).and_return(processor_charge)
    allow(ChargeProcessor).to receive(:charge_processor_success_statuses).and_return(["succeeded"])
    allow(purchase).to receive(:subscription).and_return(subscription)
    expect(subscription).to receive(:handle_purchase_success).with(purchase).and_call_original
    expect(Purchase::MarkSuccessfulService).not_to receive(:new)

    expect(described_class.new(purchase, require_final_charge_status: true).perform).to be(true)

    expect(purchase.reload).to be_successful
  end

  it "marks the preorder charge successful when a seller-held deferred preorder purchase settles" do
    preorder_link = create(:preorder_link, link: @product)
    preorder = create(:preorder, preorder_link:, seller: @seller, state: "authorization_successful")
    authorization_purchase = create(:preorder_authorization_purchase, link: @product, seller: @seller,
                                                                      preorder:, is_preorder_authorization: true)
    merchant_account = create(:merchant_account, user: @seller, currency: Currency::EUR,
                                                 charge_processor_merchant_id: "acct_preorder_settled")
    purchase = create(:purchase_in_progress, link: @product, seller: @seller, preorder:,
                                             charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                             merchant_account:, stripe_transaction_id: "ch_preorder_settled",
                                             flow_of_funds: nil)
    processor_charge = Struct.new(:id, :status, :refunded, :disputed, :flow_of_funds) do
      def refunded? = refunded
    end.new("ch_preorder_settled", "succeeded", false, false,
            FlowOfFunds.build_simple_flow_of_funds(Currency::EUR, purchase.total_transaction_cents))
    allow(ChargeProcessor).to receive(:get_or_search_charge).with(purchase).and_return(processor_charge)
    allow(ChargeProcessor).to receive(:charge_processor_success_statuses).and_return(["succeeded"])

    expect(described_class.new(purchase, require_final_charge_status: true).perform).to be(true)

    expect(purchase.reload).to be_successful
    expect(preorder.reload.state).to eq("charge_successful")
    expect(authorization_purchase.reload.purchase_state).to eq("preorder_concluded_successfully")
  end

  it "leaves a Gumroad-held combined charge purchase in progress while the charge flow of funds is missing" do
    merchant_account = create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_gumroad_combined_nil_fof")
    charge = create(:charge, seller: @seller, merchant_account:, processor_transaction_id: "ch_gumroad_nil_fof")
    purchase = create(:purchase_in_progress, link: @product, seller: @seller,
                                             charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                             merchant_account:, stripe_transaction_id: "ch_gumroad_nil_fof",
                                             flow_of_funds: nil, is_part_of_combined_charge: true)
    charge.purchases << purchase
    sibling = create(:purchase_in_progress, link: @product, seller: @seller,
                                            charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                            merchant_account:)
    charge.purchases << sibling
    processor_charge = Struct.new(:id, :status, :refunded, :disputed, :flow_of_funds) do
      def refunded? = refunded
    end.new("ch_gumroad_nil_fof", "succeeded", false, false, nil)
    allow(ChargeProcessor).to receive(:get_or_search_charge).with(purchase).and_return(processor_charge)
    allow(ChargeProcessor).to receive(:charge_processor_success_statuses).and_return(["succeeded"])
    expect(Purchase::MarkSuccessfulService).not_to receive(:new)

    # Even with mark_as_failed, a transient unsettled combined charge must stay recoverable:
    # this path has no Stripe USD fallback, so proceeding would book balances from a nil flow.
    expect(described_class.new(purchase, mark_as_failed: true).perform).to be(false)

    expect(purchase.reload).to be_in_progress
    expect(purchase.flow_of_funds).to be_nil
    expect(purchase.balance_transactions).to be_empty
  end

  it "does not mark a client-confirmed purchase failed when its finalizer is unavailable" do
    order = create(:order)
    charge = create(:charge, order:, seller: @seller, client_confirmed: true,
                             stripe_payment_intent_id: "pi_client_confirmed_recovery")
    purchase = create(:purchase_in_progress, link: @product)
    charge.purchases << purchase
    finalizer = instance_double(Order::FinalizeConfirmedChargeService, charge_intent: nil)
    allow(Order::FinalizeConfirmedChargeService).to receive(:new).with(order:, charge:).and_return(finalizer)
    allow(finalizer).to receive(:perform).and_raise(ChargeProcessorUnavailableError, "Stripe unavailable")
    allow(ErrorNotifier).to receive(:notify)

    expect(described_class.new(purchase, mark_as_failed: true).perform).to be(false)
    expect(purchase.reload).to be_in_progress
  end

  it "reports a succeeded outcome when client-confirmed finalization cannot recover the purchase" do
    order = create(:order)
    charge = create(:charge, order:, seller: @seller, client_confirmed: true,
                             stripe_payment_intent_id: "pi_client_confirmed_recovery")
    purchase = create(:purchase_in_progress, link: @product, charge_processor_id: StripeChargeProcessor.charge_processor_id)
    charge.purchases << purchase
    processor_charge = instance_double(StripeCharge, status: "succeeded", refunded: false, disputed: false)
    charge_intent = instance_double(
      StripeChargeIntent,
      succeeded?: true,
      charge: processor_charge,
      processing?: false,
      awaiting_customer_initiated_payment?: false
    )
    finalizer = instance_double(Order::FinalizeConfirmedChargeService, charge_intent:)
    allow(ChargeProcessor).to receive(:get_charge_intent)
      .with(charge.merchant_account, charge.stripe_payment_intent_id)
      .and_return(charge_intent)
    allow(Order::FinalizeConfirmedChargeService).to receive(:new)
      .with(order:, charge:, charge_intent:)
      .and_return(finalizer)
    allow(finalizer).to receive(:perform)

    service = described_class.new(purchase, require_final_charge_status: true)

    expect(service.perform).to be(false)
    expect(service.charge_outcome).to eq(:succeeded)
    expect(purchase.reload).to be_in_progress
  end

  it "does not finalize a client-confirmed purchase while its charge is pending" do
    order = create(:order)
    charge = create(:charge, order:, seller: @seller, client_confirmed: true,
                             stripe_payment_intent_id: "pi_client_confirmed_pending")
    purchase = create(:purchase_in_progress, link: @product, charge_processor_id: StripeChargeProcessor.charge_processor_id)
    charge.purchases << purchase
    processor_charge = instance_double(StripeCharge, status: "pending", refunded: false, disputed: false)
    charge_intent = instance_double(
      StripeChargeIntent,
      succeeded?: true,
      charge: processor_charge,
      processing?: false,
      awaiting_customer_initiated_payment?: false
    )
    allow(ChargeProcessor).to receive(:get_charge_intent)
      .with(charge.merchant_account, charge.stripe_payment_intent_id)
      .and_return(charge_intent)
    expect(Order::FinalizeConfirmedChargeService).not_to receive(:new)

    service = described_class.new(purchase, require_final_charge_status: true)

    expect(service.perform).to be(false)
    expect(service.charge_outcome).to eq(:pending)
    expect(purchase.reload).to be_in_progress
  end

  it "returns false and leaves the purchase in_progress when a combined charge has nil flow_of_funds (transient unsettled state)" do
    merchant_account = create(:merchant_account, user: @seller, currency: Currency::EUR,
                                                 charge_processor_merchant_id: "acct_combined_nil_fof")
    charge = create(:charge, seller: @seller, merchant_account:, processor_transaction_id: "ch_test_nil_fof")
    purchase = create(:purchase_in_progress, link: @product, seller: @seller,
                                             charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                             merchant_account:, stripe_transaction_id: "ch_test_nil_fof",
                                             flow_of_funds: nil)
    charge.purchases << purchase
    sibling = create(:purchase_in_progress, link: @product, seller: @seller,
                                            charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                            merchant_account:)
    charge.purchases << sibling
    charge_with_nil_fof = BaseProcessorCharge.new
    charge_with_nil_fof.id = "ch_test_nil_fof"
    charge_with_nil_fof.status = "succeeded"
    charge_with_nil_fof.charge_processor_id = StripeChargeProcessor.charge_processor_id
    charge_with_nil_fof.flow_of_funds = nil
    allow(ChargeProcessor).to receive(:get_or_search_charge).with(purchase).and_return(charge_with_nil_fof)
    allow(ChargeProcessor).to receive(:charge_processor_success_statuses).and_return(["succeeded"])

    expect(Purchase::SyncStatusWithChargeProcessorService.new(purchase, mark_as_failed: true).perform).to be(false)
    # Crucially: even with mark_as_failed: true, the purchase stays in_progress so the next
    # SyncStuckPurchasesJob run can re-attempt once Stripe settles balance_transaction.
    expect(purchase.reload.in_progress?).to be(true)
    expect(purchase.reload.failed?).to be(false)
  end

  it "returns false and leaves a standalone buyer-presentment purchase in_progress when flow_of_funds is nil" do
    purchase = create(:purchase,
                      link: @product,
                      purchase_state: "in_progress",
                      charge_processor_id: StripeChargeProcessor.charge_processor_id,
                      stripe_transaction_id: "ch_test_nil_fof")
    create(:purchase_presentment, purchase:, charge_presentment: nil)

    charge_with_nil_fof = BaseProcessorCharge.new
    charge_with_nil_fof.id = purchase.stripe_transaction_id
    charge_with_nil_fof.status = "succeeded"
    charge_with_nil_fof.charge_processor_id = StripeChargeProcessor.charge_processor_id
    allow(ChargeProcessor).to receive(:get_or_search_charge).with(purchase).and_return(charge_with_nil_fof)

    expect(Purchase::SyncStatusWithChargeProcessorService.new(purchase, mark_as_failed: true).perform).to be(false)
    expect(purchase.reload).to be_in_progress
  end

  it "marks the associated gift and giftee purchase as successful too in case of a successful gift purchase" do
    gift = create(:gift)
    purchase_given = build(:purchase, link: gift.link, gift_given: gift, is_gift_sender_purchase: true, chargeable: create(:chargeable), purchase_state: "in_progress")
    purchase_received = create(:purchase, link: gift.link, gift_received: purchase_given.gift, is_gift_receiver_purchase: true, purchase_state: "in_progress")

    purchase_given.process!
    expect(purchase_given.reload.in_progress?).to be(true)
    expect(purchase_given.stripe_transaction_id).not_to be(nil)

    expect(Purchase::SyncStatusWithChargeProcessorService.new(purchase_given).perform).to be(true)

    expect(purchase_given.reload.successful?).to be(true)
    expect(purchase_received.reload.gift_receiver_purchase_successful?).to be(true)
    expect(purchase_given.gift.successful?).to be(true)
  end

  it "creates a subscription in case of a successful subscription purchase" do
    product = create(:product, :is_subscription, user: @seller)
    purchase = create(:purchase, link: product, purchase_state: "in_progress", chargeable: create(:chargeable), price: product.default_price)
    purchase.process!
    expect(purchase.reload.in_progress?).to be(true)
    expect(purchase.stripe_transaction_id).not_to be(nil)
    expect(@seller.reload.unpaid_balance_cents).to eq(@initial_balance)

    expect(Purchase::SyncStatusWithChargeProcessorService.new(purchase).perform).to be(true)

    expect(purchase.reload.successful?).to be(true)
    expect(purchase.reload.subscription.alive?).to be(true)
    expect(@seller.reload.unpaid_balance_cents).to eq(@initial_balance + purchase.payment_cents)
  end

  it "does not try to create a new subscription if one is already present" do
    product = create(:product, :is_subscription, user: @seller)
    purchase = create(:purchase, link: product, purchase_state: "in_progress", chargeable: create(:chargeable), price: product.default_price)
    purchase.process!
    subscription = create(:subscription, link: product)
    subscription.purchases << purchase
    expect(purchase.reload.in_progress?).to be(true)
    expect(purchase.stripe_transaction_id).not_to be(nil)
    expect(purchase.subscription).to eq(subscription)
    expect(@seller.reload.unpaid_balance_cents).to eq(@initial_balance)

    expect(Purchase::SyncStatusWithChargeProcessorService.new(purchase).perform).to be(true)

    expect(purchase.reload.successful?).to be(true)
    expect(purchase.subscription).to eq(subscription)
    expect(purchase.reload.subscription.alive?).to be(true)
    expect(@seller.reload.unpaid_balance_cents).to eq(@initial_balance + purchase.payment_cents)
  end

  it "does not increment seller's balance again if it is already done once for this purchase" do
    purchase = create(:purchase, link: @product, purchase_state: "in_progress", chargeable: create(:chargeable))
    purchase.process!
    purchase.increment_sellers_balance!
    expect(purchase.reload.in_progress?).to be(true)
    expect(purchase.stripe_transaction_id).to be_present
    expect(@seller.reload.unpaid_balance_cents).to eq(@initial_balance + purchase.payment_cents)

    expect(Purchase::SyncStatusWithChargeProcessorService.new(purchase).perform).to be(true)

    expect(purchase.reload.successful?).to be(true)
    expect(@seller.reload.unpaid_balance_cents).to eq(@initial_balance + purchase.payment_cents)
  end

  it "marks the purchase as failed and returns false if purchase's charge was not successful" do
    purchase = create(:purchase, link: @product, purchase_state: "in_progress", chargeable: create(:chargeable_success_charge_decline))
    purchase.process!
    purchase.stripe_transaction_id = nil
    purchase.save!
    expect(purchase.reload.in_progress?).to be(true)
    expect(purchase.stripe_transaction_id).to be(nil)
    expect(@seller.reload.unpaid_balance_cents).to eq(@initial_balance)

    expect(Purchase::SyncStatusWithChargeProcessorService.new(purchase, mark_as_failed: true).perform).to be(false)
    expect(purchase.reload.failed?).to be(true)
    expect(@seller.reload.unpaid_balance_cents).to eq(@initial_balance)
  end

  it "does not raise any error and returns false if purchase's merchant account is nil" do
    purchase = create(:purchase, link: @product, purchase_state: "in_progress", chargeable: create(:chargeable_success_charge_decline))
    purchase.process!
    purchase.merchant_account_id = nil
    purchase.save!
    expect(purchase.reload.in_progress?).to be(true)
    expect(purchase.merchant_account_id).to be(nil)
    expect(@seller.reload.unpaid_balance_cents).to eq(@initial_balance)

    expect(Purchase::SyncStatusWithChargeProcessorService.new(purchase, mark_as_failed: true).perform).to be(false)
    expect(purchase.reload.failed?).to be(true)
    expect(@seller.reload.unpaid_balance_cents).to eq(@initial_balance)
  end

  it "does not mark purchase as failed if mark_as_failed flag is not set" do
    purchase = create(:purchase, link: @product, purchase_state: "in_progress", chargeable: create(:chargeable_success_charge_decline))
    purchase.process!
    purchase.merchant_account_id = nil
    purchase.save!
    expect(purchase.reload.in_progress?).to be(true)
    expect(purchase.merchant_account_id).to be(nil)
    expect(@seller.reload.unpaid_balance_cents).to eq(@initial_balance)

    expect(Purchase::SyncStatusWithChargeProcessorService.new(purchase).perform).to be(false)
    expect(purchase.reload.in_progress?).to be(true)
    expect(@seller.reload.unpaid_balance_cents).to eq(@initial_balance)
  end

  it "marks a free preorder authorization purchase as preorder_authorization_successful and returns true if mark_as_failed flag is set" do
    offer_code = create(:offer_code, products: [@product], amount_cents: 100)
    purchase = create(:free_purchase, link: @product, purchase_state: "in_progress", offer_code:, is_preorder_authorization: true, preorder: create(:preorder))
    purchase.process!

    expect(purchase.reload.in_progress?).to be(true)
    expect(purchase.free_purchase?).to be(true)
    expect(purchase.stripe_transaction_id).to be(nil)

    expect(Purchase::SyncStatusWithChargeProcessorService.new(purchase, mark_as_failed: true).perform).to be(true)

    expect(purchase.reload.preorder_authorization_successful?).to be(true)
  end

  context "for a paypal connect purchase" do
    it "marks the purchase as successful and returns true if purchase's charge was successful" do
      merchant_account = create(:merchant_account_paypal, user: @product.user,
                                                          charge_processor_merchant_id: "CJS32DZ7NDN5L", currency: "gbp")
      purchase = create(:purchase, link: @product, purchase_state: "in_progress",
                                   chargeable: create(:native_paypal_chargeable))
      purchase.process!
      purchase.stripe_transaction_id = nil
      purchase.save!
      expect(purchase.reload.in_progress?).to be(true)
      expect(purchase.stripe_transaction_id).to be(nil)
      expect(purchase.charge_processor_id).to eq(PaypalChargeProcessor.charge_processor_id)
      expect(purchase.merchant_account).to eq(merchant_account)
      expect(@seller.reload.unpaid_balance_cents).to eq(@initial_balance)

      expect(Purchase::SyncStatusWithChargeProcessorService.new(purchase).perform).to be(true)

      expect(purchase.reload.successful?).to be(true)
      expect(purchase.balance_transactions).to be_empty
      expect(@seller.reload.unpaid_balance_cents).to eq(@initial_balance)
    end

    it "synthesizes a flow of funds and heals a combined-charge PayPal purchase whose success callback was missed" do
      merchant_account = create(:merchant_account_paypal, user: @product.user,
                                                          charge_processor_merchant_id: "CJS32DZ7NDN5L", currency: "gbp")
      purchase = create(:purchase, link: @product, purchase_state: "in_progress",
                                   charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                                   merchant_account:, stripe_transaction_id: "8XC12345AB678901C")
      purchase.is_part_of_combined_charge = true
      purchase.save!
      charge = create(:charge, order: create(:order), seller: @seller, merchant_account:,
                               processor: PaypalChargeProcessor.charge_processor_id,
                               processor_transaction_id: nil,
                               amount_cents: purchase.total_transaction_cents,
                               gumroad_amount_cents: purchase.total_transaction_amount_for_gumroad_cents)
      charge.purchases << purchase

      paypal_charge = BaseProcessorCharge.new
      paypal_charge.id = purchase.stripe_transaction_id
      paypal_charge.status = "completed"
      paypal_charge.charge_processor_id = PaypalChargeProcessor.charge_processor_id
      paypal_charge.flow_of_funds = nil
      allow(ChargeProcessor).to receive(:get_or_search_charge).with(purchase).and_return(paypal_charge)

      expect(Purchase::SyncStatusWithChargeProcessorService.new(purchase).perform).to be(true)

      expect(purchase.reload.successful?).to be(true)
      expect(purchase.flow_of_funds).to be_present
      expect(purchase.flow_of_funds.gumroad_amount.currency).to eq(Currency::USD)
    end

    it "marks the purchase as failed and returns false if purchase's charge has been refunded" do
      merchant_account = create(:merchant_account_paypal, user: @product.user,
                                                          charge_processor_merchant_id: "CJS32DZ7NDN5L", currency: "gbp")
      purchase = create(:purchase, link: @product, purchase_state: "in_progress", chargeable: create(:native_paypal_chargeable))
      purchase.process!
      expect(purchase.reload.in_progress?).to be(true)
      expect(purchase.stripe_transaction_id).to be_present
      expect(purchase.merchant_account).to eq(merchant_account)
      expect(@seller.reload.unpaid_balance_cents).to eq(@initial_balance)

      PaypalRestApi.new.refund(capture_id: purchase.stripe_transaction_id, merchant_account:)

      expect(Purchase::SyncStatusWithChargeProcessorService.new(purchase, mark_as_failed: true).perform).to be(false)
      expect(purchase.reload.failed?).to be(true)
      expect(purchase.balance_transactions).to be_empty
      expect(@seller.reload.unpaid_balance_cents).to eq(@initial_balance)
    end
  end

  context "for a Stripe Connect purchase" do
    it "marks the purchase as successful and returns true if purchase's charge was successful" do
      merchant_account = create(:merchant_account_stripe_connect, user: @product.user,
                                                                  charge_processor_merchant_id: "acct_1SOb0DEwFhlcVS6d", currency: "usd")
      purchase = create(:purchase, id: 88, link: @product, purchase_state: "in_progress", merchant_account:)
      purchase.process!
      purchase.stripe_transaction_id = nil
      purchase.save!
      expect(purchase.reload.in_progress?).to be(true)
      expect(purchase.stripe_transaction_id).to be(nil)
      expect(purchase.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
      expect(purchase.merchant_account).to eq(merchant_account)
      expect(@seller.reload.unpaid_balance_cents).to eq(@initial_balance)

      expect(Purchase::SyncStatusWithChargeProcessorService.new(purchase).perform).to be(true)

      expect(purchase.reload.successful?).to be(true)
      expect(purchase.stripe_transaction_id).to eq("ch_3Mf0bBKQKir5qdfM1FZ0agOH")
      expect(purchase.balance_transactions).to be_empty
      expect(@seller.reload.unpaid_balance_cents).to eq(@initial_balance)
    end

    it "marks the purchase as failed and returns false if purchase's charge has been refunded" do
      merchant_account = create(:merchant_account_stripe_connect, user: @product.user,
                                                                  charge_processor_merchant_id: "acct_1SOb0DEwFhlcVS6d", currency: "usd")
      purchase = create(:purchase, id: 90, link: @product, purchase_state: "in_progress", merchant_account:)
      purchase.process!
      purchase.stripe_transaction_id = nil
      purchase.save!
      expect(purchase.reload.in_progress?).to be(true)
      expect(purchase.stripe_transaction_id).to be(nil)
      expect(purchase.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
      expect(purchase.merchant_account).to eq(merchant_account)
      expect(@seller.reload.unpaid_balance_cents).to eq(@initial_balance)

      expect(Purchase::SyncStatusWithChargeProcessorService.new(purchase, mark_as_failed: true).perform).to be(false)

      expect(purchase.reload.successful?).to be(false)
      expect(purchase.reload.failed?).to be(true)
      expect(purchase.stripe_transaction_id).to be(nil)
      expect(purchase.balance_transactions).to be_empty
      expect(@seller.reload.unpaid_balance_cents).to eq(@initial_balance)
    end
  end

  describe "charge receipts", vcr: false do
    let(:purchase) { create(:purchase_in_progress, link: @product, email: "buyer@example.com") }
    let!(:charge) { create(:charge, seller: @seller, merchant_account: purchase.merchant_account, purchases: [purchase]) }
    let(:processor_charge) do
      BaseProcessorCharge.new.tap do |result|
        result.id = purchase.stripe_transaction_id
        result.status = "succeeded"
        result.charge_processor_id = StripeChargeProcessor.charge_processor_id
        result.flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, charge.amount_cents)
      end
    end

    before do
      charge.order.purchases << purchase
      allow(ChargeProcessor).to receive(:get_or_search_charge).and_return(processor_charge)
      SendChargeReceiptJob.clear
      SendPurchaseReceiptJob.clear
    end

    it "enqueues the missing charge receipt after successful sync and does not replay it on another sync" do
      expect(described_class.new(purchase).perform).to be(true)
      expect(purchase.reload).to be_successful
      expect(SendPurchaseReceiptJob.jobs.size).to eq(0)
      expect(SendChargeReceiptJob.jobs.size).to eq(1)
      expect(SendChargeReceiptJob).to have_enqueued_sidekiq_job(charge.id).on("critical")

      expect(described_class.new(purchase).perform).to be(false)
      expect(SendChargeReceiptJob.jobs.size).to eq(1)
    end

    it "queues PDF stamping on the default queue" do
      @product.product_files << create(:readable_document, pdf_stamp_enabled: true)

      expect(described_class.new(purchase).perform).to be(true)
      expect(purchase.reload.url_redirect).to be_present
      expect(SendChargeReceiptJob).to have_enqueued_sidekiq_job(charge.id).on("default")
    end

    context "when receipt enqueue fails" do
      let(:enqueue_error) { RedisClient::CannotConnectError.new("receipt Redis unavailable") }

      before do
        allow(SendChargeReceiptJob).to receive(:client_push).and_raise(enqueue_error)
        allow(ErrorNotifier).to receive(:notify)
      end

      [false, true].each do |mark_as_failed|
        it "preserves successful fulfillment and returns true with mark_as_failed: #{mark_as_failed}" do
          service = described_class.new(purchase, mark_as_failed:)

          expect(service.perform).to be(true)

          expect(purchase.reload).to be_successful
          expect(purchase.url_redirect).to be_present
          expect(service.charge_outcome).to eq(:succeeded)
          expect(charge.reload).not_to be_receipt_sent
          expect(SendChargeReceiptJob.jobs.size).to eq(0)
          expect(ErrorNotifier).to have_received(:notify).with(enqueue_error).once
        end
      end

      it "contains the enqueue error at the outer commit and lets later callbacks run" do
        later_callback_ran = false

        Purchase.transaction do
          expect(described_class.new(purchase, mark_as_failed: true).perform).to be(true)
          expect(SendChargeReceiptJob).not_to have_received(:client_push)
          AfterCommitEverywhere.after_commit { later_callback_ran = true }
        end

        expect(purchase.reload).to be_successful
        expect(purchase.url_redirect).to be_present
        expect(later_callback_ran).to be(true)
        expect(charge.reload).not_to be_receipt_sent
        expect(SendChargeReceiptJob.jobs.size).to eq(0)
        expect(ErrorNotifier).to have_received(:notify).with(enqueue_error).once
      end

      it "lets SyncStuckPurchasesJob finalize the remaining purchases in the batch" do
        purchase.update!(created_at: 12.hours.ago)
        later_purchase = create(:purchase_in_progress, link: @product, email: "later-buyer@example.com", created_at: 10.hours.ago)

        SyncStuckPurchasesJob.new.perform

        expect(purchase.reload).to be_successful
        expect(purchase.url_redirect).to be_present
        expect(later_purchase.reload).to be_successful
        expect(later_purchase.url_redirect).to be_present
        expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(later_purchase.id)
        expect(charge.reload).not_to be_receipt_sent
        expect(SendChargeReceiptJob.jobs.size).to eq(0)
        expect(ErrorNotifier).to have_received(:notify).with(enqueue_error).once
      end
    end

    it "does not enqueue a receipt for an unsuccessful processor charge" do
      processor_charge.status = "failed"

      expect(described_class.new(purchase, mark_as_failed: true).perform).to be(false)
      expect(purchase.reload).to be_failed
      expect(SendChargeReceiptJob.jobs.size).to eq(0)
    end

    it "does not enqueue a receipt for an already successful purchase" do
      purchase.update!(purchase_state: "successful")

      expect(described_class.new(purchase).perform).to be(false)
      expect(SendChargeReceiptJob.jobs.size).to eq(0)
    end

    it "preserves the standalone purchase receipt when there is no charge" do
      charge.charge_purchases.destroy_all
      purchase.reload

      expect(described_class.new(purchase).perform).to be(true)
      expect(SendChargeReceiptJob.jobs.size).to eq(0)
      expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(purchase.id)
    end

    it "does not enqueue a charge receipt that was already sent" do
      charge.update!(receipt_sent: true)

      expect(described_class.new(purchase).perform).to be(true)
      expect(purchase.reload).to be_successful
      expect(SendChargeReceiptJob.jobs.size).to eq(0)
    end

    it "does not enqueue a receipt when finalization raises" do
      allow_any_instance_of(Purchase::MarkSuccessfulService).to receive(:perform).and_raise("finalization failed")
      allow(ErrorNotifier).to receive(:notify)

      expect(described_class.new(purchase).perform).to be(false)
      expect(purchase.reload).to be_in_progress
      expect(SendChargeReceiptJob.jobs.size).to eq(0)
    end

    it "preserves the return value but does not enqueue if finalization leaves the purchase unsuccessful" do
      allow_any_instance_of(Purchase::MarkSuccessfulService).to receive(:perform).and_return(false)

      expect(described_class.new(purchase).perform).to be(true)
      expect(purchase.reload).to be_in_progress
      expect(SendChargeReceiptJob.jobs.size).to eq(0)
    end

    it "waits for the surrounding transaction to commit before pushing to Redis" do
      Sidekiq::Testing.disable! do
        queued_receipts = -> { Sidekiq::Queue.new("critical").select { _1.klass == "SendChargeReceiptJob" } }
        Purchase.transaction do
          expect(described_class.new(purchase).perform).to be(true)
          expect(purchase).to be_successful
          expect(queued_receipts.call.size).to eq(0)
        end

        expect(queued_receipts.call.map(&:args)).to eq([[charge.id]])
      end
    end

    it "does not push to Redis when the surrounding transaction rolls back" do
      Sidekiq::Testing.disable! do
        Purchase.transaction do
          expect(described_class.new(purchase).perform).to be(true)
          raise ActiveRecord::Rollback
        end

        expect(purchase.reload).to be_in_progress
        expect(Sidekiq::Queue.new("critical").count { _1.klass == "SendChargeReceiptJob" }).to eq(0)
      end
    end

    it "waits for the other purchases and sends each receipt once despite duplicate jobs" do
      purchase.update!(is_part_of_combined_charge: true)
      sibling = create(:purchase_in_progress, link: @product, email: purchase.email, is_part_of_combined_charge: true)
      charge.purchases << sibling
      charge.order.purchases << sibling
      charge.update!(amount_cents: purchase.total_transaction_cents + sibling.total_transaction_cents)
      processor_charge.flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, charge.amount_cents)
      expect(ActionMailer::Base.delivery_method).to eq(:test)
      ActionMailer::Base.deliveries.clear

      expect(described_class.new(purchase).perform).to be(true)
      expect(SendChargeReceiptJob.jobs.size).to eq(1)
      SendChargeReceiptJob.perform_one
      expect(ActionMailer::Base.deliveries.size).to eq(0)
      expect(charge.reload).not_to be_receipt_sent
      expect(SendChargeReceiptJob).to have_enqueued_sidekiq_job(charge.id, 1)

      expect(described_class.new(sibling).perform).to be(true)
      expect(SendChargeReceiptJob.jobs.size).to eq(2)
      SendChargeReceiptJob.drain

      expect(ActionMailer::Base.deliveries.size).to eq(2)
      expect(CustomerEmailInfo.where(email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD).pluck(:purchase_id)).to contain_exactly(purchase.id, sibling.id)
      expect(charge.reload).to be_receipt_sent
    end

    it "keeps receipt ownership with the client-confirmed finalizer" do
      charge.update!(client_confirmed: true)
      finalizer = instance_double(Order::FinalizeConfirmedChargeService, charge_intent: nil)
      expect(Order::FinalizeConfirmedChargeService).to receive(:new).with(order: charge.order, charge:).and_return(finalizer)
      expect(finalizer).to receive(:perform) { purchase.update!(purchase_state: "successful") }
      expect(ChargeProcessor).not_to receive(:get_or_search_charge)

      expect(described_class.new(purchase).perform).to be(true)
      expect(SendChargeReceiptJob.jobs.size).to eq(0)
    end
  end

  describe "serializing competing callers" do
    let(:purchase) { create(:purchase_in_progress, link: @product, stripe_transaction_id: "ch_test") }

    it "holds the row for the whole read-then-write" do
      locked_before_processor_read = false
      allow(purchase).to receive(:with_lock).and_wrap_original do |orig, &blk|
        locked_before_processor_read = true
        orig.call(&blk)
      end
      allow(ChargeProcessor).to receive(:get_or_search_charge) do
        expect(locked_before_processor_read).to be(true)
        nil
      end

      described_class.new(purchase).perform

      expect(locked_before_processor_read).to be(true)
    end

    it "does nothing when the caller it queued behind already finalized the row" do
      # Stands in for winning the lock only after a webhook-driven sync finalized this purchase:
      # without the re-read, this caller would credit the seller a second time.
      allow(purchase).to receive(:with_lock).and_wrap_original do |orig, &blk|
        Purchase.where(id: purchase.id).update_all(purchase_state: "successful")
        orig.call(&blk)
      end
      expect(ChargeProcessor).to_not receive(:get_or_search_charge)

      expect(described_class.new(purchase, mark_as_failed: true).perform).to be(false)

      expect(purchase.reload).to be_successful
    end

    it "leaves the row to the lock holder instead of failing it when the lock cannot be taken" do
      allow(purchase).to receive(:with_lock).and_raise(ActiveRecord::LockWaitTimeout)
      allow(ErrorNotifier).to receive(:notify)

      expect(described_class.new(purchase, mark_as_failed: true).perform).to be(false)

      expect(purchase.reload).to be_in_progress
    end
  end

  describe "#charge_outcome" do
    let(:purchase) { create(:purchase_in_progress, link: @product, stripe_transaction_id: "ch_test") }

    def outcome_for(charge)
      allow(ChargeProcessor).to receive(:get_or_search_charge).and_return(charge)
      service = described_class.new(purchase)
      service.perform
      service.charge_outcome
    end

    def stripe_charge(status:, refunded: false, disputed: false)
      instance_double(StripeCharge, status:, refunded:, disputed:, flow_of_funds: nil, id: "ch_test")
    end

    it "is nil before the processor has been consulted" do
      expect(described_class.new(purchase).charge_outcome).to be_nil
    end

    it "reports a missing charge" do
      expect(outcome_for(nil)).to eq(:missing)
    end

    it "reports a refunded charge" do
      expect(outcome_for(stripe_charge(status: "succeeded", refunded: true))).to eq(:refunded)
    end

    it "reports a disputed charge" do
      expect(outcome_for(stripe_charge(status: "succeeded", disputed: true))).to eq(:disputed)
    end

    it "reports a charge that is still settling as pending, not succeeded" do
      expect(outcome_for(stripe_charge(status: "pending"))).to eq(:pending)
    end

    it "reports a charge in a non-success status" do
      expect(outcome_for(stripe_charge(status: "failed"))).to eq(:unsuccessful)
    end
  end
end
