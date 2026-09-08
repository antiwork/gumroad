# frozen_string_literal: false

describe Order::ConfirmService, :vcr do
  describe "#perform" do
    let(:seller) { create(:user) }
    let(:product_1) { create(:product, user: seller, price_cents: 5_00) }
    let(:product_2) { create(:product, user: seller, price_cents: 10_00) }

    before do
      MerchantAccount.find_or_create_by!(user_id: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id) do |ma|
        ma.charge_processor_alive_at = Time.current
      end
    end
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

    let(:sca_payment_params) { StripePaymentMethodHelper.success_with_sca.to_stripejs_params }

    let(:params) do
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
      }.merge!(common_order_params_without_payment).merge!(sca_payment_params)
    end

    it "calls Purchase::ConfirmService#perform for all purchases in the order" do
      expect(Purchase::ConfirmService).to receive(:new).exactly(2).times.and_call_original
      allow_any_instance_of(Purchase).to receive(:confirm_charge_intent!).and_return(nil)
      allow_any_instance_of(Purchase).to receive(:increment_sellers_balance!).and_return(nil)
      allow_any_instance_of(Purchase).to receive(:financial_transaction_validation).and_return(nil)

      order, _ = Order::CreateService.new(params:).perform
      expect(order.purchases.in_progress.count).to eq(2)

      charge_responses = Order::ChargeService.new(order:, params:).perform
      expect(order.purchases.in_progress.count).to eq(2)
      expect(charge_responses.size).to eq(2)
      expect(charge_responses[charge_responses.keys[0]]).to include(success: true, requires_card_action: true, client_secret: anything)
      expect(Order.find_by_secure_external_id(charge_responses[charge_responses.keys[0]][:order][:id], scope: "confirm")).to eq(order)
      expect(charge_responses[charge_responses.keys[1]]).to include(success: true, requires_card_action: true, client_secret: anything)
      expect(Order.find_by_secure_external_id(charge_responses[charge_responses.keys[1]][:order][:id], scope: "confirm")).to eq(order)

      client_secret = charge_responses[charge_responses.keys[0]][:client_secret]
      confirmation_params = { client_secret:, stripe_error: nil }
      responses, _ = Order::ConfirmService.new(order:, params: confirmation_params).perform

      expect(order.purchases.successful.count).to eq(2)
      expect(responses.size).to eq(2)
      expect(responses[responses.keys[0]]).to eq(Purchase.find(responses.keys[0]).purchase_response)
      expect(responses[responses.keys[1]]).to eq(Purchase.find(responses.keys[1]).purchase_response)
    end

    it "returns error responses for all purchases in case of SCA failure" do
      expect(Purchase::ConfirmService).to receive(:new).exactly(2).times.and_call_original

      order, _ = Order::CreateService.new(params:).perform
      expect(order.purchases.in_progress.count).to eq(2)

      charge_responses = Order::ChargeService.new(order:, params:).perform
      expect(order.purchases.in_progress.count).to eq(2)
      expect(charge_responses.size).to eq(2)
      expect(charge_responses[charge_responses.keys[0]]).to include(success: true, requires_card_action: true, client_secret: anything)
      expect(Order.find_by_secure_external_id(charge_responses[charge_responses.keys[0]][:order][:id], scope: "confirm")).to eq(order)
      expect(charge_responses[charge_responses.keys[1]]).to include(success: true, requires_card_action: true, client_secret: anything)
      expect(Order.find_by_secure_external_id(charge_responses[charge_responses.keys[1]][:order][:id], scope: "confirm")).to eq(order)

      client_secret = charge_responses[charge_responses.keys[0]][:client_secret]
      confirmation_params = { client_secret:, stripe_error: {
        code: "invalid_request_error",
        message: "We are unable to authenticate your payment method."
      }
      }
      responses, _ = Order::ConfirmService.new(order:, params: confirmation_params).perform

      expect(order.purchases.failed.count).to eq(2)
      expect(responses.size).to eq(2)
      expect(responses[responses.keys[0]]).to include({ success: false, error_message: "We are unable to authenticate your payment method." })
      expect(responses[responses.keys[1]]).to include({ success: false, error_message: "We are unable to authenticate your payment method." })
    end

    it "returns purchase error responses and offer codes in case of SCA failure with offer codes applied" do
      # The once-per-cart allocation breaks ties by permalink; pin them so product_1's line wins.
      product_1.update_column(:unique_permalink, "a_product")
      product_2.update_column(:unique_permalink, "b_product")
      offer_code = create(:offer_code, user: seller, products: [product_1, product_2], once_per_cart: true)
      params[:line_items].each { _1[:discount_code] = offer_code.code }
      params[:line_items].first[:perceived_price_cents] -= 100

      expect(Purchase::ConfirmService).to receive(:new).exactly(2).times.and_call_original

      order, _ = Order::CreateService.new(params:).perform
      expect(order.purchases.in_progress.count).to eq(2)
      expect(order.purchases.order(:id).map(&:offer_code_id)).to eq([offer_code.id, nil])

      charge_responses = Order::ChargeService.new(order:, params:).perform
      expect(order.purchases.in_progress.count).to eq(2)
      expect(charge_responses.size).to eq(2)
      expect(charge_responses[charge_responses.keys[0]]).to include(success: true, requires_card_action: true, client_secret: anything)
      expect(Order.find_by_secure_external_id(charge_responses[charge_responses.keys[0]][:order][:id], scope: "confirm")).to eq(order)
      expect(charge_responses[charge_responses.keys[1]]).to include(success: true, requires_card_action: true, client_secret: anything)
      expect(Order.find_by_secure_external_id(charge_responses[charge_responses.keys[1]][:order][:id], scope: "confirm")).to eq(order)

      client_secret = charge_responses[charge_responses.keys[0]][:client_secret]
      confirmation_params = { client_secret:, stripe_error: {
        code: "invalid_request_error",
        message: "We are unable to authenticate your payment method."
      }
      }
      responses, offer_code_responses = Order::ConfirmService.new(order:, params: confirmation_params).perform

      expect(order.purchases.failed.count).to eq(2)
      expect(responses.size).to eq(2)
      expect(responses[responses.keys[0]]).to include({ success: false, error_message: "We are unable to authenticate your payment method." })
      expect(responses[responses.keys[1]]).to include({ success: false, error_message: "We are unable to authenticate your payment method." })
      expect(offer_code_responses.size).to eq(1)
      expect(offer_code_responses[0][:code]).to eq(offer_code.code)
      expect(offer_code_responses[0][:products].size).to eq(2)
      expect(offer_code_responses[0][:products].keys).to match_array([product_1.unique_permalink, product_2.unique_permalink])
    end

    it "revalidates retry codes for lines outside the persisted order" do
      order = create(:order)
      offer_code = create(:offer_code, user: seller, products: [product_1], once_per_cart: true)
      retry_offer_codes = [{
        code: offer_code.code,
        products: {
          "failed-line" => { permalink: product_1.unique_permalink, quantity: 1 },
        },
      }]

      _, offer_code_responses = Order::ConfirmService.new(order:, params: { retry_offer_codes: }).perform

      expect(offer_code_responses).to contain_exactly(
        hash_including(code: offer_code.code.downcase, products: hash_including(product_1.unique_permalink))
      )

      offer_code.update!(max_purchase_count: 0)
      _, sold_out_responses = Order::ConfirmService.new(order:, params: { retry_offer_codes: }).perform

      expect(sold_out_responses).to be_empty
    end

    it "rejects retry-code payloads above the work limits" do
      order = create(:order)
      too_many_codes = Array.new(Order::OfferCodeRecoveryService::MAX_RETRY_OFFER_CODES + 1) do |index|
        { code: "SAVE#{index}", products: {} }
      end
      too_many_products = [{
        code: "SAVE",
        products: (Order::OfferCodeRecoveryService::MAX_RETRY_OFFER_CODE_PRODUCTS + 1).times.to_h do |index|
          [index.to_s, { permalink: product_1.unique_permalink, quantity: 1 }]
        end,
      }]

      expect(OfferCodeDiscountComputingService).not_to receive(:new)

      _, code_responses = Order::ConfirmService.new(order:, params: { retry_offer_codes: too_many_codes }).perform
      _, product_responses = Order::ConfirmService.new(order:, params: { retry_offer_codes: too_many_products }).perform

      expect(code_responses).to be_empty
      expect(product_responses).to be_empty
    end

    it "accepts one retry code for every product allowed in the cart" do
      candidates = Array.new(Cart::MAX_ALLOWED_CART_PRODUCTS) do |index|
        {
          code: "SAVE#{index}",
          products: {
            index.to_s => { permalink: "product-#{index}", quantity: 1 },
          },
        }
      end

      expect(Order::OfferCodeRecoveryService.sanitize_retry_candidates(candidates).size)
        .to eq(Cart::MAX_ALLOWED_CART_PRODUCTS)
    end

    it "discards malformed retry-code payloads before confirming purchases" do
      order = create(:order)

      expect(Purchase::ConfirmService).not_to receive(:new)
      expect do
        _, responses = Order::ConfirmService.new(order:, params: { retry_offer_codes: ["invalid"] }).perform
        expect(responses).to be_empty
      end.not_to raise_error
    end

    context "when a multi-seller India cart paused at a SetupIntent" do
      let(:india_card) do
        CreditCard.create!(
          charge_processor_id: StripeChargeProcessor.charge_processor_id,
          stripe_customer_id: "cus_confirm_india",
          processor_payment_method_id: "pm_confirm_india",
          stripe_fingerprint: "confirm_india_fingerprint",
          visual: "**** **** **** 4242",
          card_type: CardType::VISA,
          card_country: Compliance::Countries::IND.alpha2,
          expiry_month: 12,
          expiry_year: 2030
        )
      end
      let(:merchant_account) do
        MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
          create(
            :merchant_account,
            user: nil,
            charge_processor_id: StripeChargeProcessor.charge_processor_id,
            charge_processor_merchant_id: nil
          )
      end
      let(:order) { create(:order) }
      let(:charge) { create(:charge, order:, seller:, merchant_account:, stripe_setup_intent_id: "seti_confirm_india") }
      let!(:purchases) do
        [product_1, product_2].map do |product|
          purchase = create(:purchase_in_progress,
                            link: product,
                            seller:,
                            merchant_account:,
                            credit_card: india_card,
                            is_multi_buy: true,
                            processor_setup_intent_id: "seti_confirm_india")
          charge.purchases << purchase
          order.purchases << purchase
          purchase
        end
      end

      before do
        # Stripe rejects confirming a `processing` intent whose India debit is already
        # scheduled — the setup-charge path must always finalize from a retrieve-only intent.
        allow_any_instance_of(Purchase).to receive(:confirm_charge_intent!)
          .and_raise("confirm_charge_intent! must not be called for setup-charged groups")
        allow_any_instance_of(Purchase).to receive(:increment_sellers_balance!)
        allow_any_instance_of(Purchase).to receive(:financial_transaction_validation)
      end

      it "creates one combined off-session charge and reports the group's processing debit as pending" do
        setup_intent = instance_double(StripeSetupIntent, succeeded?: true)
        expect(ChargeProcessor).to receive(:get_setup_intent).with(merchant_account, "seti_confirm_india").once.and_return(setup_intent)
        charge_intent = StripeChargeIntent.new(
          payment_intent: Stripe::PaymentIntent.construct_from(id: "pi_confirm_india", status: StripeIntentStatus::PROCESSING)
        )
        captured_kwargs = nil
        create_service = instance_double(Charge::CreateService)
        expect(Charge::CreateService).to receive(:new).once do |**kwargs|
          captured_kwargs = kwargs
          create_service
        end
        allow(create_service).to receive(:perform) do
          charge.charge_intent = charge_intent
          charge
        end
        expect(Purchase::FinalizeConfirmedChargeService).to receive(:new).twice.and_call_original

        responses, = Order::ConfirmService.new(order:, params: { buyer_currency_quote: "quote-token" }).perform

        expect(captured_kwargs[:purchases]).to match_array(order.purchases.to_a)
        expect(captured_kwargs[:off_session]).to eq(true)
        expect(captured_kwargs[:setup_future_charges]).to eq(false)
        expect(captured_kwargs[:mandate_options]).to be_nil
        # The pause happened before the group's original charge, so the resume charge is the
        # first (and only) one that can lock the checkout's buyer-currency quote.
        expect(captured_kwargs[:params]).to eq(buyer_currency_quote: "quote-token")
        expect(captured_kwargs[:amount_cents]).to eq(order.purchases.sum(&:total_transaction_cents))
        expect(captured_kwargs[:merchant_account]).to eq(merchant_account)
        # Built via CreditCard#to_chargeable: a real StripeChargeableCreditCard must carry the
        # confirmed SetupIntent into the charge, which is what resolves the e-mandate.
        expect(captured_kwargs[:chargeable]).to be_a(Chargeable)
        expect(captured_kwargs[:chargeable].stripe_setup_intent_id).to eq("seti_confirm_india")

        purchases.each do |purchase|
          purchase.reload
          expect(purchase.processor_payment_intent.intent_id).to eq("pi_confirm_india")
          # The debit stays scheduled at Stripe for up to 26h; the purchase must not be marked
          # successful (or failed) until the payment_intent webhooks resolve it.
          expect(purchase.purchase_state).to eq("in_progress")
          expect(purchase.stripe_status).to eq(StripeIntentStatus::PROCESSING)
          expect(responses[purchase.id]).to eq(success: true, processing: true, permalink: purchase.link.unique_permalink)
        end
        expect(india_card.reload.stripe_payment_intent_id).to eq("pi_confirm_india")
        # The buyer may never retry the confirm; client_confirmed is what routes the intent's
        # payment_intent.succeeded / payment_failed webhooks into the async finalize/fail rails.
        expect(charge.reload.client_confirmed?).to be(true)
      end

      it "finalizes each purchase through FinalizeConfirmedChargeService when the charge succeeds synchronously" do
        setup_intent = instance_double(StripeSetupIntent, succeeded?: true)
        allow(ChargeProcessor).to receive(:get_setup_intent).and_return(setup_intent)
        stripe_charge = instance_double(StripeCharge)
        allow_any_instance_of(StripeChargeProcessor).to receive(:get_charge).with("ch_confirm_india", merchant_account: nil).and_return(stripe_charge)
        created_charge_intent = StripeChargeIntent.new(
          payment_intent: Stripe::PaymentIntent.construct_from(
            id: "pi_confirm_india",
            status: StripeIntentStatus::SUCCESS,
            latest_charge: "ch_confirm_india"
          )
        )
        create_service = instance_double(Charge::CreateService)
        allow(Charge::CreateService).to receive(:new).and_return(create_service)
        allow(create_service).to receive(:perform) do
          charge.charge_intent = created_charge_intent
          charge
        end
        finalized_purchase_ids = []
        allow(Purchase::FinalizeConfirmedChargeService).to receive(:new) do |purchase:, charge_intent:|
          expect(charge_intent).to eq(created_charge_intent)
          finalized_purchase_ids << purchase.id
          instance_double(Purchase::FinalizeConfirmedChargeService, perform: nil)
        end

        responses, = Order::ConfirmService.new(order:, params: {}).perform

        expect(finalized_purchase_ids).to match_array(purchases.map(&:id))
        purchases.each do |purchase|
          expect(purchase.reload.processor_payment_intent.intent_id).to eq("pi_confirm_india")
          expect(responses[purchase.id]).to eq(purchase.purchase_response)
        end
      end

      it "charges a Stripe Connect group with the SetupIntent's connected-account payment method instead of cloning a new one" do
        connect_account = create(:merchant_account_stripe_connect, user: seller)
        purchases.each { |purchase| purchase.update!(merchant_account: connect_account) }
        setup_intent = instance_double(StripeSetupIntent, succeeded?: true, payment_method_id: "pm_on_connect_account")
        expect(ChargeProcessor).to receive(:get_setup_intent).with(connect_account, "seti_confirm_india").once.and_return(setup_intent)
        # The mandate is bound to the payment method the SetupIntent was confirmed with; a
        # fresh clone would be a different, mandate-less method.
        expect(Stripe::PaymentMethod).not_to receive(:create)
        charge_intent = StripeChargeIntent.new(
          payment_intent: Stripe::PaymentIntent.construct_from(id: "pi_confirm_india", status: StripeIntentStatus::PROCESSING)
        )
        captured_kwargs = nil
        create_service = instance_double(Charge::CreateService)
        allow(Charge::CreateService).to receive(:new) do |**kwargs|
          captured_kwargs = kwargs
          create_service
        end
        allow(create_service).to receive(:perform) do
          charge.charge_intent = charge_intent
          charge
        end

        responses, = Order::ConfirmService.new(order:, params: {}).perform

        stripe_chargeable = captured_kwargs[:chargeable].get_chargeable_for(StripeChargeProcessor.charge_processor_id)
        expect(stripe_chargeable.stripe_charge_params).to eq(payment_method: "pm_on_connect_account")
        purchases.each do |purchase|
          expect(responses[purchase.id]).to eq(success: true, processing: true, permalink: purchase.link.unique_permalink)
        end
      end

      it "finalizes an already-charged group from a retrieved intent instead of re-confirming it" do
        purchases.each do |purchase|
          purchase.create_processor_payment_intent!(intent_id: "pi_confirm_india")
          purchase.update!(stripe_status: StripeIntentStatus::PROCESSING)
        end
        charge_intent = StripeChargeIntent.new(
          payment_intent: Stripe::PaymentIntent.construct_from(id: "pi_confirm_india", status: StripeIntentStatus::PROCESSING)
        )
        expect(ChargeProcessor).to receive(:get_charge_intent).with(merchant_account, "pi_confirm_india").once.and_return(charge_intent)
        expect(ChargeProcessor).not_to receive(:get_setup_intent)
        expect(Charge::CreateService).not_to receive(:new)

        responses, = Order::ConfirmService.new(order:, params: {}).perform

        purchases.each do |purchase|
          expect(purchase.reload.purchase_state).to eq("in_progress")
          expect(responses[purchase.id]).to eq(success: true, processing: true, permalink: purchase.link.unique_permalink)
        end
      end

      it "fails the group without charging when the SetupIntent did not succeed" do
        setup_intent = instance_double(StripeSetupIntent, succeeded?: false)
        allow(ChargeProcessor).to receive(:get_setup_intent).and_return(setup_intent)
        expect(Charge::CreateService).not_to receive(:new)

        responses, = Order::ConfirmService.new(order:, params: {}).perform

        purchases.each do |purchase|
          expect(purchase.reload.purchase_state).to eq("failed")
        end
        expect(responses.values).to all(
          include(success: false, error_message: "We couldn't authorize your card for this payment. Please try again or use a different payment method.")
        )
      end

      it "does not finalize a paid purchase whose group charge could not be created" do
        setup_intent = instance_double(StripeSetupIntent, succeeded?: true)
        allow(ChargeProcessor).to receive(:get_setup_intent).and_return(setup_intent)
        create_service = instance_double(Charge::CreateService)
        allow(Charge::CreateService).to receive(:new).and_return(create_service)
        # A rescued processor outcome: Charge::CreateService returns the charge with no intent.
        allow(create_service).to receive(:perform) do
          charge.charge_intent = nil
          charge
        end

        responses, = Order::ConfirmService.new(order:, params: {}).perform

        purchases.each do |purchase|
          expect(purchase.reload.purchase_state).to eq("failed")
          expect(purchase.processor_payment_intent).to be_nil
        end
        expect(responses.values).to all(include(success: false))
        # No intent exists for webhooks to resolve, so the charge must not be flagged for
        # the async client-confirm finalize rails.
        expect(charge.reload.client_confirmed?).to be(false)
      end

      it "does not charge when the browser reported a card authentication error" do
        expect(ChargeProcessor).not_to receive(:get_setup_intent)
        expect(Charge::CreateService).not_to receive(:new)

        confirmation_params = {
          stripe_error: {
            code: "invalid_request_error",
            message: "We are unable to authenticate your payment method."
          }
        }
        responses, = Order::ConfirmService.new(order:, params: confirmation_params).perform

        purchases.each do |purchase|
          expect(purchase.reload.purchase_state).to eq("failed")
        end
        expect(responses.values).to all(include(success: false))
      end
    end
  end
end
