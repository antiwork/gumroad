# frozen_string_literal: false

describe "Order checkout payment flow recording", :vcr do
  include StripeMerchantAccountHelper

  let(:seller_1) { create(:user) }
  let(:seller_2) { create(:user) }
  let(:product_1) { create(:product, user: seller_1, price_cents: 10_00) }
  let(:product_2) { create(:product, user: seller_2, price_cents: 20_00) }
  let(:free_product) { create(:product, user: seller_1, price_cents: 0) }
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
  let(:reusable_payment_params) { StripePaymentMethodHelper.success.to_stripejs_params(prepare_future_payments: true) }
  let(:sca_payment_params) { StripePaymentMethodHelper.success_with_sca.to_stripejs_params }
  let(:fail_payment_params) { StripePaymentMethodHelper.decline_expired.to_stripejs_params }

  def line_item(product)
    { uid: "uid-#{product.unique_permalink}", permalink: product.unique_permalink, perceived_price_cents: product.price_cents, quantity: 1 }
  end

  def perform(params, buyer: nil)
    order, _ = Order::CreateService.new(params:, buyer:).perform
    Order::ChargeService.new(order:, params:).perform
    order.reload
  end

  context "with a new card collected via the Payment Element" do
    it "records payment_element through a successful charge" do
      create(:merchant_account, user: seller_1, charge_processor_merchant_id: create_verified_stripe_account(country: "US").id)
      params = { line_items: [line_item(product_1)] }.merge(common_order_params_without_payment).merge(successful_payment_params)
      params[:payment_details_source] = "payment_element"

      order = perform(params)

      expect(order.purchases.successful.count).to eq(1)
      expect(order.purchases.sole.purchase_payment_flow).to have_attributes(
        payment_details_source: "payment_element",
        payment_details_transport: "payment_method",
        stripe_payment_method_type: "card"
      )
    end
  end

  context "with a new card collected via the CardElement" do
    it "records card_element through a successful charge" do
      create(:merchant_account, user: seller_1, charge_processor_merchant_id: create_verified_stripe_account(country: "US").id)
      params = { line_items: [line_item(product_1)] }.merge(common_order_params_without_payment).merge(successful_payment_params)
      params[:payment_details_source] = "card_element"

      order = perform(params)

      expect(order.purchases.successful.count).to eq(1)
      expect(order.purchases.sole.purchase_payment_flow.payment_details_source).to eq("card_element")
    end
  end

  context "with a wallet payment" do
    it "records payment_request from the server-authoritative wallet_type even when the client hint disagrees" do
      create(:merchant_account, user: seller_1, charge_processor_merchant_id: create_verified_stripe_account(country: "US").id)
      params = { line_items: [line_item(product_1)] }.merge(common_order_params_without_payment).merge(successful_payment_params)
      params[:wallet_type] = "apple_pay"
      params[:payment_details_source] = "card_element"

      order = perform(params)

      expect(order.purchases.successful.count).to eq(1)
      expect(order.purchases.sole.purchase_payment_flow.payment_details_source).to eq("payment_request")
    end
  end

  context "with a saved card" do
    it "records saved_payment_method through a successful charge" do
      create(:merchant_account, user: seller_1, charge_processor_merchant_id: create_verified_stripe_account(country: "US").id)
      buyer = create(:user)
      buyer.credit_card = create(:credit_card)
      buyer.save!

      params = { line_items: [line_item(product_1)] }.merge(common_order_params_without_payment)
      params[:payment_details_source] = "saved_payment_method"

      order = perform(params, buyer:)

      expect(order.purchases.successful.count).to eq(1)
      expect(order.purchases.sole.purchase_payment_flow.payment_details_source).to eq("saved_payment_method")
    end
  end

  context "when the charge is declined" do
    it "still records the payment flow for the failed purchase" do
      params = { line_items: [line_item(product_1)] }.merge(common_order_params_without_payment).merge(fail_payment_params)
      params[:payment_details_source] = "payment_element"

      order = perform(params)

      expect(order.purchases.failed.count).to eq(1)
      expect(order.purchases.sole.purchase_payment_flow).to have_attributes(
        payment_details_source: "payment_element",
        payment_details_transport: "payment_method",
        stripe_payment_method_type: "card"
      )
    end
  end

  context "when the charge requires SCA" do
    it "records the payment flow while the purchase awaits confirmation" do
      create(:merchant_account, user: seller_1, charge_processor_merchant_id: create_verified_stripe_account(country: "US").id)
      params = { line_items: [line_item(product_1)] }.merge(common_order_params_without_payment).merge(sca_payment_params)
      params[:payment_details_source] = "payment_element"

      order = perform(params)

      expect(order.purchases.in_progress.count).to eq(1)
      expect(order.purchases.sole.purchase_payment_flow.payment_details_source).to eq("payment_element")
    end
  end

  context "with a multi-seller cart" do
    it "records the payment flow on every charged purchase" do
      create(:merchant_account, user: seller_1, charge_processor_merchant_id: create_verified_stripe_account(country: "US").id)
      create(:merchant_account, user: seller_2, charge_processor_merchant_id: create_verified_stripe_account(country: "US").id)
      params = { line_items: [line_item(product_1), line_item(product_2)] }
        .merge(common_order_params_without_payment).merge(reusable_payment_params)
      params[:payment_details_source] = "payment_element"

      order = perform(params)

      expect(order.purchases.successful.count).to eq(2)
      expect(order.charges.count).to eq(2)
      flows = order.purchases.map(&:purchase_payment_flow)
      expect(flows).to all(be_present)
      expect(flows.map(&:payment_details_source).uniq).to eq(["payment_element"])
    end
  end

  context "with a mixed free-plus-paid cart" do
    it "records the paid purchase but not the free purchase" do
      create(:merchant_account, user: seller_1, charge_processor_merchant_id: create_verified_stripe_account(country: "US").id)
      params = { line_items: [line_item(product_1), line_item(free_product)] }
        .merge(common_order_params_without_payment).merge(successful_payment_params)
      params[:payment_details_source] = "payment_element"

      order = perform(params)

      paid_purchase = order.purchases.find_by(link_id: product_1.id)
      free_purchase = order.purchases.find_by(link_id: free_product.id)
      expect(paid_purchase.purchase_payment_flow.payment_details_source).to eq("payment_element")
      expect(free_purchase.purchase_payment_flow).to be_nil
    end
  end

  context "with a free purchase" do
    it "does not record a payment flow" do
      params = { line_items: [line_item(free_product)] }.merge(common_order_params_without_payment)

      order = perform(params)

      expect(order.purchases.sole.purchase_payment_flow).to be_nil
    end
  end

  context "with a PayPal purchase" do
    it "does not record a payment flow" do
      params = { line_items: [line_item(product_1)] }.merge(common_order_params_without_payment).merge(paypal_order_id: "PAY-123")

      order, _ = Order::CreateService.new(params:).perform

      expect(order.purchases.sole.purchase_payment_flow).to be_nil
    end
  end
end
