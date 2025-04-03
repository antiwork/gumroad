# frozen_string_literal: true

describe PaypalRestApi, :vcr do
  let(:api_object) { PaypalRestApi.new }
  let(:paypal_auth_token) { "Bearer A21AAI6Qq9kon0Z2N7R6ed3OXwkNxFraroKppGHWHJUU5w-MlQBKKcZd_WlHbQJgh79HLaWQmEnRyj3GZdRW9FMqRbbSkcmBA" }

  # Business accounts from our sandbox setup and their merchant IDs generated after manually completing onboarding
  let(:creator_email) { "sb-c7jpx2385730@business.example.com" }
  let(:creator_paypal_merchant_id) { "MN7CSWD6RCNJ8" }
  let(:creator_2_email) { "sb-byx2u2205460@business.example.com" }
  let(:creator_2_paypal_merchant_id) { "B66YJBBNCRW6L" }

  let(:creator) { create(:user, email: creator_email) }
  let(:creator_merchant_account) { create(:merchant_account_paypal, user: creator, charge_processor_merchant_id: creator_paypal_merchant_id) }
  let(:link) { create(:product, user: creator, unique_permalink: "aa") }

  let(:creator_2) { create(:user, email: creator_2_email) }
  let(:creator_2_merchant_account) { create(:merchant_account_paypal, user: creator_2, charge_processor_merchant_id: creator_2_paypal_merchant_id) }
  let(:link2) { create(:product, user: creator_2, unique_permalink: "bb") }
  let(:purchase) do
    create(:purchase, link:, shipping_cents: 150, price_cents: 1500, tax_cents: 75, quantity: 3)
  end

  before do
    creator_merchant_account
    creator_2_merchant_account
    allow_any_instance_of(PaypalPartnerRestCredentials).to receive(:auth_token).and_return(paypal_auth_token)
  end

  describe "#create_order" do
    let(:create_order_response) do
      api_object.create_order(purchase_unit_info: PaypalChargeProcessor.paypal_order_info(purchase))
    end

    it "creates new order as requested and returns the order details in response" do
      allow_any_instance_of(Purchase).to receive(:external_id).and_return("G_-mnBf9b1j9A7a4ub4nFQ==")

      expect(create_order_response.status_code).to eq(201)

      order = create_order_response.result
      expect(order.id).to_not be(nil)
      expect(order.status).to eq("CREATED")

      purchase_unit = order.purchase_units[0]
      expect(purchase_unit.invoice_id).to eq(purchase.external_id)
      expect(purchase_unit.amount.value).to eq("15.00")
      expect(purchase_unit.amount.breakdown.item_total.value).to eq("13.50")
      expect(purchase_unit.amount.breakdown.shipping.value).to eq("1.50")
      expect(purchase_unit.amount.breakdown.tax_total.value).to eq("0.00")
      expect(purchase_unit.payee.merchant_id).to eq(creator_paypal_merchant_id)
      expect(purchase_unit.items[0].quantity).to eq("3")
      expect(purchase_unit.items[0].unit_amount.value).to eq("4.50")
      expect(purchase_unit.items[0].sku).to eq(link.unique_permalink)
      expect(purchase_unit.payment_instruction.platform_fees.size).to eq(1)
      expect(purchase_unit.payment_instruction.platform_fees.first.amount.value).to eq("1.00")

      urls = order.links
      expect(urls.size).to eq(4)
      expect(urls.map(&:rel)).to match_array(%w(self approve update capture))
    end

    it "limits the product (item) names to 127 characters" do
      product_with_very_long_name = create(:product, user: creator, unique_permalink: "cc",
                                                     name: "Conversation Casanova Mastery: 48 Conversation Tactics, Techniques and Mindsets to "\
                                                 "Start Conversations, Flirt like a Master and Never Run Out of Things to Say, The Book")
      purchase = create(:purchase, link: product_with_very_long_name)

      response  = api_object.create_order(purchase_unit_info: PaypalChargeProcessor.paypal_order_info(purchase))

      order = response.result
      expect(order.id).to_not be(nil)
      expect(order.status).to eq("CREATED")
      expect(order.purchase_units[0].items[0].name).to eq(purchase.link.name.strip[0...PaypalChargeProcessor::MAXIMUM_ITEM_NAME_LENGTH])
    end

    it "Formats the amounts to not have a thousands separator and have 2 decimal places" do
      purchase = create(:purchase, link:, price_cents: 153399, quantity: 3)

      response  = api_object.create_order(purchase_unit_info: PaypalChargeProcessor.paypal_order_info(purchase))

      order = response.result
      expect(order.id).to_not be(nil)
      expect(order.status).to eq("CREATED")

      purchase_unit = order.purchase_units[0]
      expect(purchase_unit.amount.value).to eq("1533.99")
      expect(purchase_unit.amount.breakdown.item_total.value).to eq("1533.99")
      expect(purchase_unit.payee.merchant_id).to eq(creator_paypal_merchant_id)
      expect(purchase_unit.items[0].quantity).to eq("3")
      expect(purchase_unit.items[0].unit_amount.value).to eq("511.33")
      expect(purchase_unit.items[0].sku).to eq(link.unique_permalink)
      expect(purchase_unit.payment_instruction.platform_fees.size).to eq(1)
      expect(purchase_unit.payment_instruction.platform_fees.first.amount.value).to eq("76.94")

      urls = order.links
      expect(urls.size).to eq(4)
      expect(urls.map(&:rel)).to match_array(%w(self approve update capture))
    end

    it "does not have decimal values for amounts in TWD" do
      allow_any_instance_of(MerchantAccount).to receive(:currency).and_return("TWD")

      purchase = create(:purchase, link:, price_cents: 1500, quantity: 3)

      response  = api_object.create_order(purchase_unit_info: PaypalChargeProcessor.paypal_order_info(purchase))

      order = response.result
      expect(order.id).to be_present
      expect(order.status).to eq("CREATED")

      purchase_unit = order.purchase_units[0]
      expect(purchase_unit.amount.value).to eq("450.00")
      expect(purchase_unit.amount.breakdown.item_total.value).to eq("450.00")
      expect(purchase_unit.payee.merchant_id).to eq(creator_paypal_merchant_id)
      expect(purchase_unit.items[0].quantity).to eq("3")
      expect(purchase_unit.items[0].unit_amount.value).to eq("150.00")
      expect(purchase_unit.items[0].sku).to eq(link.unique_permalink)
    end

    it "calculates the amounts in HUF correctly" do
      allow_any_instance_of(MerchantAccount).to receive(:currency).and_return("HUF")

      purchase = create(:purchase, link:, price_cents: 1500, quantity: 3)

      response  = api_object.create_order(purchase_unit_info: PaypalChargeProcessor.paypal_order_info(purchase))

      order = response.result
      expect(order.id).to be_present
      expect(order.status).to eq("CREATED")

      purchase_unit = order.purchase_units[0]
      expect(purchase_unit.amount.value).to eq("3705.00")
      expect(purchase_unit.amount.breakdown.item_total.value).to eq("3705.00")
      expect(purchase_unit.payee.merchant_id).to eq(creator_paypal_merchant_id)
      expect(purchase_unit.items[0].quantity).to eq("3")
      expect(purchase_unit.items[0].unit_amount.value).to eq("1235.00")
      expect(purchase_unit.items[0].sku).to eq(link.unique_permalink)
    end

    it "uses items details if passed to create new order" do
      seller = create(:user)
      merchant_account = create(:merchant_account_paypal, user: seller, charge_processor_merchant_id: "B66YJBBNCRW6L")

      charge = create(:charge, seller:, merchant_account:, amount_cents: 10_00, gumroad_amount_cents: 2_50)
      charge.purchases << create(:purchase, price_cents: 200, fee_cents: 48, link: create(:product, unique_permalink: "h"))
      charge.purchases << create(:purchase, price_cents: 800, fee_cents: 102, link: create(:product, unique_permalink: "c"))

      paypal_auth_token = "Bearer A21AAIwPw4niCFO4ziUTNt46mLva8lrt4cmMackDZFvFNVqEIpkEMzh6z-tt5cb2Sw6YcPsT1kVfuBdsVkAnZcAx9XFiMiGIw"
      allow_any_instance_of(PaypalPartnerRestCredentials).to receive(:auth_token).and_return(paypal_auth_token)
      allow_any_instance_of(Charge).to receive(:external_id).and_return("G_-mnBf9b1j9A7a4ub4nFQ==")

      order_response = api_object.create_order(purchase_unit_info: PaypalChargeProcessor.paypal_order_info_from_charge(charge))
      expect(order_response.status_code).to eq(201)

      order = order_response.result
      expect(order.id).to_not be(nil)
      expect(order.status).to eq("CREATED")

      purchase_unit = order.purchase_units[0]
      expect(purchase_unit.invoice_id).to eq(charge.external_id)
      expect(purchase_unit.amount.value).to eq("10.00")
      expect(purchase_unit.amount.breakdown.item_total.value).to eq("10.00")
      expect(purchase_unit.amount.breakdown.shipping.value).to eq("0.00")
      expect(purchase_unit.amount.breakdown.tax_total.value).to eq("0.00")
      expect(purchase_unit.payee.merchant_id).to eq(merchant_account.charge_processor_merchant_id)
      expect(purchase_unit.items[0].quantity).to eq("1")
      expect(purchase_unit.items[0].unit_amount.value).to eq("2.00")
      expect(purchase_unit.items[0].sku).to eq(charge.purchases.first.link.unique_permalink)
      expect(purchase_unit.items[1].quantity).to eq("1")
      expect(purchase_unit.items[1].unit_amount.value).to eq("8.00")
      expect(purchase_unit.items[1].sku).to eq(charge.purchases.last.link.unique_permalink)
      expect(purchase_unit.payment_instruction.platform_fees.size).to eq(1)
      expect(purchase_unit.payment_instruction.platform_fees.first.amount.value).to eq("1.50")

      urls = order.links
      expect(urls.size).to eq(4)
      expect(urls.map(&:rel)).to match_array(%w(self approve update capture))
    end
  end

  describe "update_order" do
    it "updates the paypal order with the product info" do
      allow_any_instance_of(Purchase).to receive(:external_id).and_return("G_-mnBf9b1j9A7a4ub4nFQ==")
      purchase = create(:purchase, link:, shipping_cents: 150, price_cents: 1500, tax_cents: 75, quantity: 3,
                                   merchant_account: creator_merchant_account)

      create_order_response = api_object.create_order(purchase_unit_info: PaypalChargeProcessor.paypal_order_info(purchase))
      order = create_order_response.result
      purchase_unit = order.purchase_units[0]
      expect(purchase_unit.amount.value).to eq("15.00")
      expect(purchase_unit.amount.breakdown.item_total.value).to eq("13.50")
      expect(purchase_unit.amount.breakdown.shipping.value).to eq("1.50")
      expect(purchase_unit.amount.breakdown.tax_total.value).to eq("0.00")
      expect(purchase_unit.items[0].quantity).to eq("3")
      expect(purchase_unit.items[0].unit_amount.value).to eq("4.50")
      expect(purchase_unit.items[0].sku).to eq(link.unique_permalink)
      expect(purchase_unit.payment_instruction.platform_fees.size).to eq(1)
      expect(purchase_unit.payment_instruction.platform_fees.first.amount.value).to eq("1.65")

      purchase.update!(price_cents: 750, total_transaction_cents: 750, shipping_cents: 75, fee_cents: 83)
      api_object.update_order(order_id: order.id,
                              purchase_unit_info: PaypalChargeProcessor.paypal_order_info(purchase))

      fetch_order_response = api_object.fetch_order(order_id: order.id)
      order = fetch_order_response.result
      purchase_unit = order.purchase_units[0]
      expect(purchase_unit.amount.value).to eq("7.50")
      expect(purchase_unit.amount.breakdown.item_total.value).to eq("6.75")
      expect(purchase_unit.amount.breakdown.shipping.value).to eq("0.75")
      expect(purchase_unit.amount.breakdown.tax_total.value).to eq("0.00")
      expect(purchase_unit.items[0].quantity).to eq("3")
      expect(purchase_unit.items[0].unit_amount.value).to eq("2.25")
      expect(purchase_unit.items[0].sku).to eq(link.unique_permalink)
      expect(purchase_unit.payment_instruction.platform_fees.size).to eq(1)
      expect(purchase_unit.payment_instruction.platform_fees.first.amount.value).to eq("0.83")
    end
  end

  describe "#fetch_order" do
    context "when invalid order id is passed" do
      let(:fetch_order_response) { api_object.fetch_order(order_id: "invalid_order") }

      it "returns error" do
        expect(fetch_order_response.status_code).to eq(404)
        expect(fetch_order_response.result.name).to eq("RESOURCE_NOT_FOUND")
      end
    end

    context "when valid order id is passed" do
      let(:create_order_response) do
        api_object.create_order(purchase_unit_info: PaypalChargeProcessor.paypal_order_info(purchase))
      end

      let(:fetch_order_response) { api_object.fetch_order(order_id: create_order_response.result.id) }

      it "returns order details" do
        expect(fetch_order_response.status_code).to eq(200)

        order = fetch_order_response.result
        expect(order.id).to eq(create_order_response.result.id)
        expect(order.status).to eq("CREATED")

        purchase_unit = order.purchase_units[0]
        expect(purchase_unit.amount.value).to eq("15.00")
        expect(purchase_unit.amount.breakdown.item_total.value).to eq("13.50")
        expect(purchase_unit.amount.breakdown.shipping.value).to eq("1.50")
        expect(purchase_unit.amount.breakdown.tax_total.value).to eq("0.00")
        expect(purchase_unit.payee.merchant_id).to eq(creator_paypal_merchant_id)
        expect(purchase_unit.items[0].quantity).to eq("3")
        expect(purchase_unit.items[0].unit_amount.value).to eq("4.50")
        expect(purchase_unit.items[0].sku).to eq(link.unique_permalink)
        expect(purchase_unit.payment_instruction.platform_fees.size).to eq(1)
        expect(purchase_unit.payment_instruction.platform_fees.first.amount.value).to eq("1.00")

        urls = order.links
        expect(urls.size).to eq(4)
        expect(urls.map(&:rel)).to match_array(%w(self approve update capture))
      end
    end
  end

  describe "#capture" do
    context "when invalid order id is passed" do
      let(:capture_order_response) { api_object.capture(order_id: "invalid_order", billing_agreement_id: nil) }

      it "returns error" do
        expect(capture_order_response.status_code).to eq(404)
        expect(capture_order_response.result.name).to eq("RESOURCE_NOT_FOUND")
      end
    end

    context "when valid order id is passed" do
      let(:capture_order_response) { api_object.capture(order_id: "9XX680320L106570A", billing_agreement_id: "B-38D505255T217912K") }

      it "returns success with valid order having completed status" do
        expect(capture_order_response.status_code).to eq(201)

        order = capture_order_response.result
        expect(order.id).to_not be(nil)
        expect(order.status).to eq("COMPLETED")
        expect(order.payer.email_address).to eq("paypal-gr-integspecs@gumroad.com")

        purchase_unit = order.purchase_units[0]
        expect(purchase_unit.amount.value).to eq("15.00")
        expect(purchase_unit.amount.breakdown.item_total.value).to eq("13.50")
        expect(purchase_unit.amount.breakdown.shipping.value).to eq("1.50")
        expect(purchase_unit.amount.breakdown.tax_total.value).to eq("0.00")
        expect(purchase_unit.payee.merchant_id).to eq(creator_paypal_merchant_id)
        expect(purchase_unit.items[0].quantity).to eq("3")
        expect(purchase_unit.items[0].unit_amount.value).to eq("4.50")
        expect(purchase_unit.items[0].sku).to eq(link.unique_permalink)
        expect(purchase_unit.payments.captures.size).to eq(1)
        expect(purchase_unit.payment_instruction.platform_fees.size).to eq(1)
        expect(purchase_unit.payment_instruction.platform_fees.first.amount.value).to eq("1.00")

        capture = purchase_unit.payments.captures[0]
        expect(capture.status).to eq("COMPLETED")
        expect(capture.disbursement_mode).to eq("INSTANT")
        expect(capture.amount.value).to eq("15.00")
        expect(capture.seller_receivable_breakdown.gross_amount.value).to eq("15.00")
        expect(capture.seller_receivable_breakdown.paypal_fee.value).to eq("0.74")
        expect(capture.seller_receivable_breakdown.platform_fees.size).to eq(1)
        expect(capture.seller_receivable_breakdown.platform_fees.first.amount.value).to eq("1.00")
        expect(capture.seller_receivable_breakdown.platform_fees.first.payee.merchant_id).to eq(PAYPAL_PARTNER_ID)
        expect(capture.seller_receivable_breakdown.net_amount.value).to eq("13.26")
        urls = capture.links
        expect(urls.size).to eq(3)
        expect(urls.map(&:rel)).to match_array(%w(self refund up))
      end
    end
  end

  describe "#refund" do
    context "when it a full refund" do
      context "when invalid capture id is passed" do
        let(:refund_response) { api_object.refund(capture_id: "invalid_capture_id", merchant_account: creator_merchant_account) }

        it "returns error" do
          expect(refund_response.status_code).to eq(404)
          expect(refund_response.result.name).to eq("RESOURCE_NOT_FOUND")
        end
      end

      context "when valid capture id is passed" do
        let(:refund_response) { api_object.refund(capture_id: "09G1866342856691M", merchant_account: creator_merchant_account) }

        it "refunds full amount" do
          expect(refund_response.status_code).to eq(201)

          refund = refund_response.result
          expect(refund.id).to_not be(nil)
          expect(refund.status).to eq("COMPLETED")
          expect(refund.seller_payable_breakdown.gross_amount.value).to eq("15.00")
          expect(refund.seller_payable_breakdown.paypal_fee.value).to eq("0.44")
          expect(refund.seller_payable_breakdown.platform_fees.first.amount.value).to eq("1.00")
          expect(refund.seller_payable_breakdown.net_amount.value).to eq("13.56")
          expect(refund.seller_payable_breakdown.total_refunded_amount.value).to eq("15.00")
          urls_2 = refund.links
          expect(urls_2.size).to eq(2)
          expect(urls_2.map(&:rel)).to match_array(%w(self up))
        end
      end
    end

    context "when it is partial refund" do
      context "when invalid capture id is passed" do
        let(:refund_response) { api_object.refund(capture_id: "invalid_capture_id", merchant_account: creator_2_merchant_account, amount: 2.0) }

        it "returns error" do
          expect(refund_response.status_code).to eq(404)
          expect(refund_response.result.name).to eq("RESOURCE_NOT_FOUND")
        end
      end

      context "when valid capture id is passed" do
        let(:refund_response) { api_object.refund(capture_id: "3K928030M4826742P", merchant_account: creator_merchant_account, amount: 2.0) }

        it "refunds the passed amount" do
          expect(refund_response.status_code).to eq(201)

          refund = refund_response.result
          expect(refund.id).to_not be(nil)
          expect(refund.status).to eq("COMPLETED")
          expect(refund.seller_payable_breakdown.gross_amount.value).to eq("2.00")
          expect(refund.seller_payable_breakdown.paypal_fee.value).to eq("0.06")
          expect(refund.seller_payable_breakdown.platform_fees.first.amount.value).to eq("0.10")
          expect(refund.seller_payable_breakdown.net_amount.value).to eq("1.84")
          expect(refund.seller_payable_breakdown.total_refunded_amount.value).to eq("2.00")
          urls_2 = refund.links
          expect(urls_2.size).to eq(2)
          expect(urls_2.map(&:rel)).to match_array(%w(self up))
        end
      end
    end

    context "when merchant account details are not available" do
      it "gets the paypal account details from original order and refunds successfully" do
        purchase = create(:purchase, stripe_transaction_id: "8FM61749P03946202", paypal_order_id: "9UG44304FR485654R")
        expect_any_instance_of(PaypalRestApi).to receive(:fetch_order).with(order_id: purchase.paypal_order_id).and_call_original

        refund_response = api_object.refund(capture_id: purchase.stripe_transaction_id)

        expect(refund_response.status_code).to eq(201)

        refund = refund_response.result
        expect(refund.id).to be_present
        expect(refund.status).to eq("COMPLETED")
        expect(refund.seller_payable_breakdown.gross_amount.value).to eq("5.00")
        expect(refund.seller_payable_breakdown.paypal_fee.value).to eq("0.15")
        expect(refund.seller_payable_breakdown.platform_fees.first.amount.value).to eq("0.30")
        expect(refund.seller_payable_breakdown.net_amount.value).to eq("4.55")
        expect(refund.seller_payable_breakdown.total_refunded_amount.value).to eq("5.00")
        urls = refund.links
        expect(urls.size).to eq(2)
        expect(urls.map(&:rel)).to match_array(%w(self up))
      end
    end
  end
end
