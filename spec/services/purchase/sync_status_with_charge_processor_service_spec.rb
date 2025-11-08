# frozen_string_literal: false

describe Purchase::SyncStatusWithChargeProcessorService, :vcr do
  before do
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
end
