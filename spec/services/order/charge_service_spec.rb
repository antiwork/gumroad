# frozen_string_literal: false

describe Order::ChargeService, :vcr do
  describe "#perform" do
    let(:seller_1) { create(:user) }
    let(:seller_2) { create(:user) }
    let(:seller_3) { create(:user) }
    let(:product_1) { create(:product, user: seller_1, price_cents: 10_00) }
    let(:product_2) { create(:product, user: seller_1, price_cents: 20_00) }
    let(:free_product_1) { create(:product, user: seller_1, price_cents: 0) }
    let(:free_product_2) { create(:product, user: seller_1, price_cents: 0) }
    let(:free_trial_membership_product) do
      recurrence_price_values = [
        { BasePrice::Recurrence::MONTHLY => { enabled: true, price: 100 }, BasePrice::Recurrence::YEARLY => { enabled: true, price: 1000 } },
        { BasePrice::Recurrence::MONTHLY => { enabled: true, price: 50 }, BasePrice::Recurrence::YEARLY => { enabled: true, price: 500 } }
      ]
      create(:membership_product_with_preset_tiered_pricing,
             :with_free_trial_enabled,
             user: seller_2,
             recurrence_price_values:)
    end
    let(:product_3) { create(:product, user: seller_2, price_cents: 30_00) }
    let(:product_4) { create(:product, user: seller_2, price_cents: 40_00) }
    let(:product_5) { create(:product, user: seller_2, price_cents: 50_00, discover_fee_per_thousand: 300) }
    let(:product_6) { create(:product, user: seller_3, price_cents: 60_00) }
    let(:product_7) { create(:product, user: seller_3, price_cents: 70_00, discover_fee_per_thousand: 400) }
    let(:browser_guid) { SecureRandom.uuid }

    let(:common_order_params_without_payment) do
      {
        email: "buyer@gumroad.com",
        cc_zipcode: "12345",
        purchase: {
          full_name: "Edgar Gumstein",
          street_address: "123 Gum Road",
          country: "US",
          state: "CA",
          city: "San Francisco",
          zip_code: "94117"
        },
        browser_guid:,
        ip_address: "0.0.0.0",
        session_id: "a107d0b7ab5ab3c1eeb7d3aaf9792977",
        is_mobile: false,
      }
    end

    let(:successful_payment_params) { StripePaymentMethodHelper.success.to_stripejs_params }
    let(:sca_payment_params) { StripePaymentMethodHelper.success_with_sca.to_stripejs_params }
    let(:indian_mandate_payment_params) { StripePaymentMethodHelper.success_indian_card_mandate.to_stripejs_params }
    let(:pp_native_payment_params) do
      {
        billing_agreement_id: "B-12345678910"
      }
    end
    let(:fail_payment_params) { StripePaymentMethodHelper.decline_expired.to_stripejs_params }
    let(:payment_params_with_future_charges) { StripePaymentMethodHelper.success.to_stripejs_params(prepare_future_payments: true) }

    let(:line_items_params) do
      {
        line_items: [
          {
            uid: "unique-id-0",
            permalink: product_1.unique_permalink,
            perceived_price_cents: product_1.price_cents,
            quantity: 1
          },
          {
            uid: "unique-id-1",
            permalink: product_2.unique_permalink,
            perceived_price_cents: product_2.price_cents,
            quantity: 1
          }
        ]
      }
    end

    let(:multi_seller_line_items_params) do
      {
        line_items: [
          {
            uid: "unique-id-0",
            permalink: product_1.unique_permalink,
            perceived_price_cents: product_1.price_cents,
            quantity: 1
          },
          {
            uid: "unique-id-1",
            permalink: product_2.unique_permalink,
            perceived_price_cents: product_2.price_cents,
            quantity: 1
          },
          {
            uid: "unique-id-2",
            permalink: product_3.unique_permalink,
            perceived_price_cents: product_3.price_cents,
            quantity: 1
          },
          {
            uid: "unique-id-3",
            permalink: product_4.unique_permalink,
            perceived_price_cents: product_4.price_cents,
            quantity: 1
          },
          {
            uid: "unique-id-4",
            permalink: product_5.unique_permalink,
            perceived_price_cents: product_5.price_cents,
            quantity: 1
          },
          {
            uid: "unique-id-5",
            permalink: product_6.unique_permalink,
            perceived_price_cents: product_6.price_cents,
            quantity: 1
          },
          {
            uid: "unique-id-6",
            permalink: product_7.unique_permalink,
            perceived_price_cents: product_7.price_cents,
            quantity: 1
          }
        ]
      }
    end

    before do
      allow_any_instance_of(Purchase).to receive(:flat_fee_applicable?).and_return(true)
    end

    it "charges all purchases in the order with the payment method provided in params" do
      params = line_items_params.merge!(common_order_params_without_payment).merge!(successful_payment_params)

      order, _ = Order::CreateService.new(params:).perform
      expect(order.purchases.in_progress.count).to eq(2)

      charge_responses = Order::ChargeService.new(order:, params:).perform

      expect(order.reload.purchases.successful.count).to eq(2)
      expect(order.charges.count).to eq(1)
      charge = order.charges.last
      expect(charge.purchases.successful.count).to eq(2)
      expect(charge.amount_cents).to eq(order.purchases.sum(&:total_transaction_cents))
      expect(charge.gumroad_amount_cents).to eq(order.purchases.sum(&:total_transaction_amount_for_gumroad_cents))
      expect(order.purchases.pluck(:stripe_transaction_id).uniq).to eq([charge.processor_transaction_id])
      expect(order.purchases.pluck(:stripe_fingerprint).uniq).to eq([charge.payment_method_fingerprint])
      expect(charge.processor_fee_cents).to be_present
      expect(charge.processor_fee_currency).to eq("usd")
      expect(charge.stripe_payment_intent_id).to be_present
      expect(charge.purchases.where(link_id: product_1.id).last.fee_cents).to eq(209)
      expect(charge.purchases.where(link_id: product_2.id).last.fee_cents).to eq(338)

      expect(charge_responses.size).to eq(2)
      expect(charge_responses[charge_responses.keys[0]]).to eq(order.purchases.first.purchase_response)
      expect(charge_responses[charge_responses.keys[1]]).to eq(order.purchases.last.purchase_response)
    end

    it "charges all purchases in the order when seller has a Stripe merchant account" do
      seller_stripe_account = create(:merchant_account_stripe, user: seller_1)

      params = line_items_params.merge!(common_order_params_without_payment).merge!(successful_payment_params)

      order, _ = Order::CreateService.new(params:).perform
      expect(order.purchases.in_progress.count).to eq(2)

      charge_responses = Order::ChargeService.new(order:, params:).perform

      expect(order.reload.purchases.successful.count).to eq(2)
      expect(order.charges.count).to eq(1)
      charge = order.charges.last
      expect(charge.purchases.successful.count).to eq(2)
      expect(charge.merchant_account).to eq(seller_stripe_account)
      expect(charge.amount_cents).to eq(order.purchases.sum(&:total_transaction_cents))
      expect(charge.gumroad_amount_cents).to eq(order.purchases.sum(&:total_transaction_amount_for_gumroad_cents))
      expect(order.purchases.pluck(:stripe_transaction_id).uniq).to eq([charge.processor_transaction_id])
      expect(order.purchases.pluck(:stripe_fingerprint).uniq).to eq([charge.payment_method_fingerprint])
      expect(charge.processor_fee_cents).to be_present
      expect(charge.processor_fee_currency).to eq("usd")
      expect(charge.stripe_payment_intent_id).to be_present
      expect(charge.purchases.where(link_id: product_1.id).last.merchant_account).to eq(seller_stripe_account)
      expect(charge.purchases.where(link_id: product_1.id).last.fee_cents).to eq(209)
      expect(charge.purchases.where(link_id: product_2.id).last.merchant_account).to eq(seller_stripe_account)
      expect(charge.purchases.where(link_id: product_2.id).last.fee_cents).to eq(338)

      expect(charge_responses.size).to eq(2)
      expect(charge_responses[charge_responses.keys[0]]).to eq(order.purchases.first.purchase_response)
      expect(charge_responses[charge_responses.keys[1]]).to eq(order.purchases.last.purchase_response)
    end

    it "charges 2.9% + 30c of processor fee when seller has a Stripe merchant account and existing credit card is used for payment" do
      seller_stripe_account = create(:merchant_account_stripe, user: seller_1)

      buyer = create(:user)
      buyer.credit_card = create(:credit_card)
      buyer.save!

      params = line_items_params.merge!(common_order_params_without_payment)

      order, _ = Order::CreateService.new(params:, buyer:).perform
      expect(order.purchases.in_progress.count).to eq(2)

      charge_responses = Order::ChargeService.new(order:, params:).perform

      expect(order.reload.purchases.successful.count).to eq(2)
      expect(order.charges.count).to eq(1)
      charge = order.charges.last
      expect(charge.purchases.successful.count).to eq(2)
      expect(charge.merchant_account).to eq(seller_stripe_account)
      expect(charge.amount_cents).to eq(order.purchases.sum(&:total_transaction_cents))
      expect(charge.gumroad_amount_cents).to eq(order.purchases.sum(&:total_transaction_amount_for_gumroad_cents))
      expect(order.purchases.pluck(:stripe_transaction_id).uniq).to eq([charge.processor_transaction_id])
      expect(order.purchases.pluck(:stripe_fingerprint).uniq).to eq([charge.payment_method_fingerprint])
      expect(charge.processor_fee_cents).to be_present
      expect(charge.processor_fee_currency).to eq("usd")
      expect(charge.stripe_payment_intent_id).to be_present
      expect(charge.credit_card).to eq(buyer.credit_card)
      expect(charge.payment_method_fingerprint).to eq(buyer.credit_card.stripe_fingerprint)
      expect(charge.purchases.where(link_id: product_1.id).last.merchant_account).to eq(seller_stripe_account)
      expect(charge.purchases.where(link_id: product_1.id).last.fee_cents).to eq(209)
      expect(charge.purchases.where(link_id: product_2.id).last.merchant_account).to eq(seller_stripe_account)
      expect(charge.purchases.where(link_id: product_2.id).last.fee_cents).to eq(338)

      expect(charge_responses.size).to eq(2)
      expect(charge_responses[charge_responses.keys[0]]).to eq(order.purchases.first.purchase_response)
      expect(charge_responses[charge_responses.keys[1]]).to eq(order.purchases.last.purchase_response)
    end

    it "does not charge Gumroad fee and taxes when seller has a Brazilian Stripe Connect account" do
      seller_1.update!(check_merchant_account_is_linked: true)
      seller_stripe_account = create(:merchant_account_stripe_connect, user: seller_1, country: "BR", charge_processor_merchant_id: "acct_1QADdCGy0w4tFIUe")

      params = line_items_params.merge!(common_order_params_without_payment).merge!(successful_payment_params)

      order, _ = Order::CreateService.new(params:).perform
      expect(order.purchases.in_progress.count).to eq(2)

      charge_responses = Order::ChargeService.new(order:, params:).perform

      expect(order.reload.purchases.successful.count).to eq(2)
      expect(order.charges.count).to eq(1)
      charge = order.charges.last
      expect(charge.purchases.successful.count).to eq(2)
      expect(charge.merchant_account).to eq(seller_stripe_account)
      expect(charge.amount_cents).to eq(order.purchases.sum(&:total_transaction_cents))
      expect(charge.gumroad_amount_cents).to eq 0
      expect(order.purchases.pluck(:stripe_transaction_id).uniq).to eq([charge.processor_transaction_id])
      expect(order.purchases.pluck(:stripe_fingerprint).uniq).to eq([charge.payment_method_fingerprint])
      expect(charge.processor_fee_cents).to be_present
      expect(charge.processor_fee_currency).to eq("brl")
      expect(charge.stripe_payment_intent_id).to be_present
      expect(charge.purchases.where(link_id: product_1.id).last.merchant_account).to eq(seller_stripe_account)
      expect(charge.purchases.where(link_id: product_1.id).last.fee_cents).to eq 0
      expect(charge.purchases.where(link_id: product_2.id).last.merchant_account).to eq(seller_stripe_account)
      expect(charge.purchases.where(link_id: product_2.id).last.fee_cents).to eq 0

      expect(charge_responses.size).to eq(2)
      expect(charge_responses[charge_responses.keys[0]]).to eq(order.purchases.first.purchase_response)
      expect(charge_responses[charge_responses.keys[1]]).to eq(order.purchases.last.purchase_response)
    end

    it "charges the correct custom fee when seller has custom Gumroad fee set" do
      seller_1.update!(custom_fee_per_thousand: 50)

      seller_stripe_account = create(:merchant_account_stripe, user: seller_1)

      params = line_items_params.merge!(common_order_params_without_payment).merge!(successful_payment_params)

      order, _ = Order::CreateService.new(params:).perform
      expect(order.purchases.in_progress.count).to eq(2)

      charge_responses = Order::ChargeService.new(order:, params:).perform

      expect(order.reload.purchases.successful.count).to eq(2)
      expect(order.charges.count).to eq(1)
      charge = order.charges.last
      expect(charge.purchases.successful.count).to eq(2)
      expect(charge.merchant_account).to eq(seller_stripe_account)
      expect(charge.amount_cents).to eq(order.purchases.sum(&:total_transaction_cents))
      expect(charge.gumroad_amount_cents).to eq 397
      expect(order.purchases.pluck(:stripe_transaction_id).uniq).to eq([charge.processor_transaction_id])
      expect(order.purchases.pluck(:stripe_fingerprint).uniq).to eq([charge.payment_method_fingerprint])
      expect(charge.stripe_payment_intent_id).to be_present
      expect(charge.purchases.where(link_id: product_1.id).last.merchant_account).to eq(seller_stripe_account)
      expect(charge.purchases.where(link_id: product_1.id).last.fee_cents).to eq 159 # 5% of $10 + 50c + 2.9% of $10 + 30c
      expect(charge.purchases.where(link_id: product_2.id).last.merchant_account).to eq(seller_stripe_account)
      expect(charge.purchases.where(link_id: product_2.id).last.fee_cents).to eq 238 # 5% of $20 + 50c + 2.9% of $20 + 30c

      expect(charge_responses.size).to eq(2)
      expect(charge_responses[charge_responses.keys[0]]).to eq(order.purchases.first.purchase_response)
      expect(charge_responses[charge_responses.keys[1]]).to eq(order.purchases.last.purchase_response)
    end

    it "returns error responses for all purchases if corresponding charge fails" do
      params = line_items_params.merge!(common_order_params_without_payment).merge!(fail_payment_params)

      order, _ = Order::CreateService.new(params:).perform
      expect(order.purchases.in_progress.count).to eq(2)

      charge_responses = Order::ChargeService.new(order:, params:).perform
      expect(order.purchases.failed.count).to eq(2)
      expect(charge_responses.size).to eq(2)
      expect(charge_responses[charge_responses.keys[0]]).to include(success: false, error_message: "Your card has expired.")
      expect(charge_responses[charge_responses.keys[1]]).to include(success: false, error_message: "Your card has expired.")
    end

    it "returns error responses with USD formatted price even when product display currency is EUR" do
      allow_any_instance_of(Purchase)
        .to receive(:get_rate).with(Currency::EUR.to_sym).and_return(0.8)

      eur_product = create(:product, user: seller_1, price_cents: 10_00, price_currency_type: Currency::EUR)
      eur_line_items_params = {
        line_items: [
          {
            uid: "unique-id-eur",
            permalink: eur_product.unique_permalink,
            perceived_price_cents: eur_product.price_cents,
            quantity: 1
          }
        ]
      }
      params = eur_line_items_params.merge!(common_order_params_without_payment).merge!(fail_payment_params)

      order, _ = Order::CreateService.new(params:).perform
      expect(order.purchases.in_progress.count).to eq(1)

      charge_responses = Order::ChargeService.new(order:, params:).perform
      expect(order.purchases.failed.count).to eq(1)
      expect(charge_responses.size).to eq(1)
      response = charge_responses[charge_responses.keys[0]]
      expect(response).to include(success: false)
      expect(response[:formatted_price]).to eq("$12.50")
    end

    it "returns SCA response if the payment method provided in params requires SCA" do
      params = line_items_params.merge!(common_order_params_without_payment).merge!(sca_payment_params)

      order, _ = Order::CreateService.new(params:).perform
      expect(order.purchases.in_progress.count).to eq(2)

      charge_responses = Order::ChargeService.new(order:, params:).perform
      expect(order.purchases.in_progress.count).to eq(2)
      expect(charge_responses.size).to eq(2)
      expect(charge_responses[charge_responses.keys[0]]).to include(success: true, requires_card_action: true, client_secret: anything,
                                                                    order: { id: order.external_id, stripe_connect_account_id: nil })
      expect(charge_responses[charge_responses.keys[1]]).to include(success: true, requires_card_action: true, client_secret: anything,
                                                                    order: { id: order.external_id, stripe_connect_account_id: nil })
    end

    it "creates multiple charges in case of purchases from different sellers" do
      params = multi_seller_line_items_params.merge!(common_order_params_without_payment).merge!(payment_params_with_future_charges)

      order, _ = Order::CreateService.new(params:).perform
      expect(order.purchases.in_progress.count).to eq(7)

      charge_responses = nil

      expect do
        expect do
          charge_responses = Order::ChargeService.new(order:, params:).perform
        end.to change(Charge, :count).by(3)
      end.to change(Purchase.successful, :count).by(7)

      expect(order.reload.charges.count).to eq(3)
      expect(order.purchases.successful.count).to eq(7)

      charge1 = order.charges.first
      expect(charge1.seller).to eq(product_1.user)
      expect(charge1.purchases.successful.count).to eq(2)
      expect(charge1.purchases.pluck(:link_id)).to eq([product_1.id, product_2.id])
      expect(charge1.amount_cents).to eq(product_1.price_cents + product_2.price_cents)
      expect(charge1.amount_cents).to eq(charge1.purchases.sum(:total_transaction_cents))
      expect(charge1.gumroad_amount_cents).to eq(charge1.purchases.sum(&:total_transaction_amount_for_gumroad_cents))

      charge2 = order.charges.second
      expect(charge2.seller).to eq(product_3.user)
      expect(charge2.purchases.successful.count).to eq(3)
      expect(charge2.purchases.pluck(:link_id)).to eq([product_3.id, product_4.id, product_5.id])
      expect(charge2.amount_cents).to eq(product_3.price_cents + product_4.price_cents + product_5.price_cents)
      expect(charge2.amount_cents).to eq(charge2.purchases.sum(:total_transaction_cents))
      expect(charge2.gumroad_amount_cents).to eq(charge2.purchases.sum(&:total_transaction_amount_for_gumroad_cents))

      charge3 = order.charges.last
      expect(charge3.seller).to eq(product_6.user)
      expect(charge3.purchases.successful.count).to eq(2)
      expect(charge3.purchases.pluck(:link_id)).to eq([product_6.id, product_7.id])
      expect(charge3.amount_cents).to eq(product_6.price_cents + product_7.price_cents)
      expect(charge3.amount_cents).to eq(charge3.purchases.sum(:total_transaction_cents))
      expect(charge3.gumroad_amount_cents).to eq(charge3.purchases.sum(&:total_transaction_amount_for_gumroad_cents))

      expect(charge_responses.size).to eq(7)
      7.times do |index|
        expect(charge_responses[charge_responses.keys[index]]).to eq(order.purchases[index].purchase_response)
      end
    end

    it "creates a charge with no amount if all the items from a seller are free" do
      free_line_items_params = {
        line_items: [
          {
            uid: "unique-id-0",
            permalink: free_product_1.unique_permalink,
            perceived_price_cents: 0,
            quantity: 1
          },
          {
            uid: "unique-id-1",
            permalink: free_product_2.unique_permalink,
            perceived_price_cents: 0,
            quantity: 1
          }
        ]
      }
      params = free_line_items_params.merge!(common_order_params_without_payment)

      order, _ = Order::CreateService.new(params:).perform
      expect(order.purchases.in_progress.count).to eq(2)

      charge_responses = Order::ChargeService.new(order:, params:).perform

      expect(order.reload.purchases.successful.count).to eq(2)
      expect(order.charges.count).to eq(1)
      charge = order.charges.last
      expect(charge.purchases.successful.count).to eq(2)
      expect(charge.amount_cents).to be(nil)
      expect(charge.gumroad_amount_cents).to be(nil)
      expect(charge.processor).to be(nil)
      expect(charge.processor_transaction_id).to be(nil)
      expect(charge.merchant_account_id).to be(nil)

      expect(charge_responses.size).to eq(2)
      expect(charge_responses[charge_responses.keys[0]]).to eq(order.purchases.first.purchase_response)
      expect(charge_responses[charge_responses.keys[1]]).to eq(order.purchases.last.purchase_response)
    end

    it "creates a charge with no amount for a free trial membership product" do
      line_items_params = {
        line_items: [
          {
            uid: "unique-id-0",
            permalink: free_trial_membership_product.unique_permalink,
            perceived_price_cents: 100_00,
            is_free_trial_purchase: true,
            perceived_free_trial_duration: {
              amount: free_trial_membership_product.free_trial_duration_amount,
              unit: free_trial_membership_product.free_trial_duration_unit
            },
            quantity: 1
          }
        ]
      }
      params = line_items_params.merge!(common_order_params_without_payment).merge!(successful_payment_params)

      order, _ = Order::CreateService.new(params:).perform
      expect(order.purchases.in_progress.count).to eq(1)

      charge_responses = Order::ChargeService.new(order:, params:).perform

      expect(order.reload.purchases.not_charged.count).to eq(1)
      expect(order.charges.count).to eq(1)
      charge = order.charges.last
      expect(charge.purchases.not_charged.count).to eq(1)
      expect(charge.amount_cents).to be(nil)
      expect(charge.gumroad_amount_cents).to be(nil)
      expect(charge.processor).to be(nil)
      expect(charge.processor_transaction_id).to be(nil)
      expect(charge.merchant_account_id).to be(nil)
      expect(charge.credit_card_id).to be_present
      expect(charge.stripe_setup_intent_id).to be_present

      expect(charge_responses.size).to eq(1)
      expect(charge_responses[charge_responses.keys[0]]).to eq(order.purchases.last.purchase_response)
    end

    it "creates charges with no amounts for sellers whose items don't require an immediate payment" do
      line_items_params = {
        line_items: [
          {
            uid: "unique-id-0",
            permalink: free_trial_membership_product.unique_permalink,
            perceived_price_cents: 100_00,
            is_free_trial_purchase: true,
            perceived_free_trial_duration: {
              amount: free_trial_membership_product.free_trial_duration_amount,
              unit: free_trial_membership_product.free_trial_duration_unit
            },
            quantity: 1
          },
          {
            uid: "unique-id-1",
            permalink: free_product_2.unique_permalink,
            perceived_price_cents: 0,
            quantity: 1
          }
        ]
      }
      params = line_items_params.merge!(common_order_params_without_payment).merge!(successful_payment_params)

      order, _ = Order::CreateService.new(params:).perform
      expect(order.purchases.in_progress.count).to eq(2)

      charge_responses = Order::ChargeService.new(order:, params:).perform

      expect(order.reload.purchases.not_charged.count).to eq(1)
      expect(order.reload.purchases.successful.count).to eq(1)
      expect(order.charges.count).to eq(2)

      charge_1 = order.charges.where(seller_id: seller_1.id).last
      expect(charge_1.purchases.successful.count).to eq(1)
      expect(charge_1.amount_cents).to be(nil)
      expect(charge_1.gumroad_amount_cents).to be(nil)
      expect(charge_1.processor).to be(nil)
      expect(charge_1.processor_transaction_id).to be(nil)
      expect(charge_1.merchant_account_id).to be(nil)
      expect(charge_1.credit_card_id).to be(nil)
      expect(charge_1.stripe_setup_intent_id).to be(nil)

      charge_2 = order.charges.where(seller_id: seller_2.id).last
      expect(charge_2.purchases.not_charged.count).to eq(1)
      expect(charge_2.amount_cents).to be(nil)
      expect(charge_2.gumroad_amount_cents).to be(nil)
      expect(charge_2.processor).to be(nil)
      expect(charge_2.processor_transaction_id).to be(nil)
      expect(charge_2.merchant_account_id).to be(nil)
      expect(charge_2.credit_card_id).to be_present
      expect(charge_2.stripe_setup_intent_id).to be_present

      expect(charge_responses.size).to eq(2)
      expect(charge_responses[charge_responses.keys[0]]).to eq(order.purchases.first.purchase_response)
      expect(charge_responses[charge_responses.keys[1]]).to eq(order.purchases.last.purchase_response)
    end

    it "includes free purchases in charges along with the paid purchases" do
      expect(CustomerMailer).not_to receive(:receipt)

      free_line_items_params = {
        line_items: [
          {
            uid: "unique-id-7",
            permalink: free_trial_membership_product.unique_permalink,
            perceived_price_cents: 100_00,
            is_free_trial_purchase: true,
            perceived_free_trial_duration: {
              amount: free_trial_membership_product.free_trial_duration_amount,
              unit: free_trial_membership_product.free_trial_duration_unit
            },
            quantity: 1
          },
          {
            uid: "unique-id-8",
            permalink: free_product_1.unique_permalink,
            perceived_price_cents: 0,
            quantity: 1
          },
          {
            uid: "unique-id-9",
            permalink: free_product_2.unique_permalink,
            perceived_price_cents: 0,
            quantity: 1
          }
        ]
      }
      line_items_params = { line_items: multi_seller_line_items_params[:line_items] + free_line_items_params[:line_items] }
      params = line_items_params.merge!(common_order_params_without_payment).merge!(payment_params_with_future_charges)

      order, _ = Order::CreateService.new(params:).perform
      expect(order.purchases.in_progress.count).to eq(10)

      charge_responses = nil

      expect do
        charge_responses = Order::ChargeService.new(order:, params:).perform
      end.to change(Charge, :count).by(3)
        .and change(Purchase.successful, :count).by(9)
        .and change(Purchase.not_charged, :count).by(1)

      expect(order.reload.charges.count).to eq(3)
      expect(order.purchases.successful.count).to eq(9)
      expect(order.purchases.not_charged.count).to eq(1)

      charge1 = order.charges.first
      expect(charge1.seller).to eq(product_1.user)
      expect(charge1.purchases.successful.count).to eq(4)
      expect(charge1.purchases.pluck(:link_id)).to eq([product_1.id, product_2.id, free_product_1.id, free_product_2.id])
      expect(charge1.amount_cents).to eq(product_1.price_cents + product_2.price_cents)
      expect(charge1.amount_cents).to eq(charge1.purchases.sum(:total_transaction_cents))
      expect(charge1.gumroad_amount_cents).to eq(charge1.purchases.sum(&:total_transaction_amount_for_gumroad_cents))

      charge2 = order.charges.second
      expect(charge2.seller).to eq(product_3.user)
      expect(charge2.purchases.successful.count).to eq(3)
      expect(charge2.purchases.not_charged.count).to eq(1)
      expect(charge2.purchases.pluck(:link_id)).to eq([product_3.id, product_4.id, product_5.id, free_trial_membership_product.id])
      expect(charge2.amount_cents).to eq(product_3.price_cents + product_4.price_cents + product_5.price_cents)
      expect(charge2.amount_cents).to eq(charge2.purchases.successful.sum(:total_transaction_cents))
      expect(charge2.gumroad_amount_cents).to eq(charge2.purchases.successful.sum(&:total_transaction_amount_for_gumroad_cents))

      charge3 = order.charges.last
      expect(charge3.seller).to eq(product_6.user)
      expect(charge3.purchases.successful.count).to eq(2)
      expect(charge3.purchases.pluck(:link_id)).to eq([product_6.id, product_7.id])
      expect(charge3.amount_cents).to eq(product_6.price_cents + product_7.price_cents)
      expect(charge3.amount_cents).to eq(charge3.purchases.sum(:total_transaction_cents))
      expect(charge3.gumroad_amount_cents).to eq(charge3.purchases.sum(&:total_transaction_amount_for_gumroad_cents))

      expect(charge_responses.size).to eq(10)
      expect(charge_responses.values).to match_array(order.purchases.map { _1.purchase_response })
    end

    context "when payment method requires mandate" do
      let!(:membership_product) { create(:membership_product_with_preset_tiered_pricing, user: seller_1) }
      let!(:membership_product_2) { create(:membership_product, price_cents: 10_00, user: seller_1) }

      let(:single_line_item_params_for_mandate) do
        {
          line_items: [
            {
              uid: "unique-id-0",
              permalink: membership_product.unique_permalink,
              perceived_price_cents: 3_00,
              quantity: 1
            }
          ]
        }
      end

      let(:line_items_params_for_mandate) do
        {
          line_items: [
            {
              uid: "unique-id-0",
              permalink: membership_product.unique_permalink,
              perceived_price_cents: 3_00,
              quantity: 1
            },
            {
              uid: "unique-id-1",
              permalink: membership_product_2.unique_permalink,
              perceived_price_cents: 10_00,
              quantity: 1
            }
          ]
        }
      end

      it "creates a mandate for a single membership purchase" do
        params = single_line_item_params_for_mandate.merge!(common_order_params_without_payment).merge!(indian_mandate_payment_params)

        order, _ = Order::CreateService.new(params:).perform
        expect(order.purchases.in_progress.count).to eq(1)

        Order::ChargeService.new(order:, params:).perform
        expect(order.purchases.in_progress.count).to eq(1)
        expect(order.charges.count).to eq(1)

        charge = order.charges.last
        expect(charge.credit_card.stripe_payment_intent_id).to be_present
        expect(charge.credit_card.stripe_payment_intent_id).to eq(charge.stripe_payment_intent_id)

        stripe_payment_intent = Stripe::PaymentIntent.retrieve(charge.credit_card.stripe_payment_intent_id)
        expect(stripe_payment_intent.payment_method_options.card.mandate_options).to be_present

        mandate_options = stripe_payment_intent.payment_method_options.card.mandate_options
        expect(mandate_options.amount).to eq(3_00)
        expect(mandate_options.amount_type).to eq("maximum")
        expect(mandate_options.interval).to eq("month")
        expect(mandate_options.interval_count).to eq(1)
      end

      it "creates a mandate for multiple membership purchases" do
        params = line_items_params_for_mandate.merge!(common_order_params_without_payment).merge!(indian_mandate_payment_params)

        order, _ = Order::CreateService.new(params:).perform
        expect(order.purchases.in_progress.count).to eq(2)

        Order::ChargeService.new(order:, params:).perform
        expect(order.purchases.in_progress.count).to eq(2)
        expect(order.charges.count).to eq(1)

        charge = order.charges.last
        expect(charge.credit_card.stripe_payment_intent_id).to be_present
        expect(charge.credit_card.stripe_payment_intent_id).to eq(charge.stripe_payment_intent_id)

        stripe_payment_intent = Stripe::PaymentIntent.retrieve(charge.credit_card.stripe_payment_intent_id)
        expect(stripe_payment_intent.payment_method_options.card.mandate_options).to be_present

        mandate_options = stripe_payment_intent.payment_method_options.card.mandate_options
        expect(mandate_options.amount).to eq(10_00)
        expect(mandate_options.amount_type).to eq("maximum")
        expect(mandate_options.interval).to eq("sporadic")
        expect(mandate_options.interval_count).to be nil
      end
    end
  end

  describe "#mandate_options_for_stripe" do
    let!(:seller) { create(:user) }
    let!(:membership_product) { create(:membership_product_with_preset_tiered_pricing, user: seller) }
    let!(:membership_product_2) { create(:membership_product, price_cents: 10_00, user: seller) }

    it "returns mandate options of the purchase in case of single purchase" do
      allow_any_instance_of(StripeChargeablePaymentMethod).to receive(:country).and_return("IN")

      order = create(:order)
      purchase = create(:purchase_in_progress, link: membership_product, is_original_subscription_purchase: true,
                                               total_transaction_cents: 5_00, card_country: "IN", charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                               chargeable: create(:chargeable))
      order.purchases << purchase

      allow_any_instance_of(Purchase).to receive(:subscription_duration).and_return("biannually")
      expect_any_instance_of(Purchase).to receive(:mandate_options_for_stripe).and_call_original

      charge_service = Order::ChargeService.new(order:, params: nil)
      mandate_options = charge_service.mandate_options_for_stripe(purchases: [purchase])

      expect(mandate_options[:payment_method_options][:card][:mandate_options][:interval]).to eq("month")
      expect(mandate_options[:payment_method_options][:card][:mandate_options][:interval_count]).to eq(6)
      expect(mandate_options[:payment_method_options][:card][:mandate_options][:amount]).to eq(5_00)
      expect(mandate_options[:payment_method_options][:card][:mandate_options][:amount_type]).to eq("maximum")
    end

    it "returns mandate options with sporadic interval and amount as maximum of the price of included purchases" do
      order = create(:order)
      purchase = create(:purchase_in_progress, link: membership_product, is_original_subscription_purchase: true,
                                               total_transaction_cents: 3_00, card_country: "IN", charge_processor_id: StripeChargeProcessor.charge_processor_id)
      purchase2 = create(:purchase_in_progress, link: membership_product, is_original_subscription_purchase: true,
                                                total_transaction_cents: 10_00, card_country: "IN", charge_processor_id: StripeChargeProcessor.charge_processor_id)
      order.purchases << purchase
      order.purchases << purchase2

      expect_any_instance_of(Purchase).not_to receive(:mandate_options_for_stripe).and_call_original

      charge_service = Order::ChargeService.new(order:, params: nil)
      mandate_options = charge_service.mandate_options_for_stripe(purchases: order.purchases)

      expect(mandate_options[:payment_method_options][:card][:mandate_options][:interval]).to eq("sporadic")
      expect(mandate_options[:payment_method_options][:card][:mandate_options][:interval_count]).to be nil
      expect(mandate_options[:payment_method_options][:card][:mandate_options][:amount]).to eq(10_00)
      expect(mandate_options[:payment_method_options][:card][:mandate_options][:amount_type]).to eq("maximum")
    end
  end
end
