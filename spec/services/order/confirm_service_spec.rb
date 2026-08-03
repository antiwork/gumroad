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
  end
end
