# frozen_string_literal: false

require "shared_examples/order_association_with_cart_post_checkout"

describe Order::CreateService, :vcr do
  let(:seller_1) { create(:user) }
  let(:seller_2) { create(:user) }
  let(:price_1) { 5_00 }
  let(:price_2) { 10_00 }
  let(:price_3) { 10_00 }
  let(:price_4) { 10_00 }
  let(:price_5) { 10_00 }
  let(:product_1) { create(:product, user: seller_1, price_cents: price_1) }
  let(:product_2) { create(:product, user: seller_1, price_cents: price_2) }
  let(:product_3) { create(:product, user: seller_1, price_cents: price_3) }
  let(:product_4) { create(:product, user: seller_2, price_cents: price_4) }
  let(:product_5) { create(:product, user: seller_2, price_cents: price_5, discover_fee_per_thousand: 300) }
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
        }
      ]
    }.merge(common_order_params_without_payment)
  end

  def signed_buyer_currency_quote(seller:, product:, rate:, canonical_components:)
    payload = {
      "charges" => [
        {
          "seller_id" => seller.id,
          "stripe_fx_quote_expires_at" => 30.minutes.from_now.iso8601,
          "listed_currency_rates" => { product.unique_permalink => rate },
          "listed_currency_codes" => { product.unique_permalink => product.price_currency_type.to_s.downcase },
          "canonical_line_components" => canonical_components,
        }
      ]
    }
    Rails.application.message_verifier(Checkout::BuyerCurrencyQuote::TOKEN_PURPOSE).generate(payload)
  end

  describe "#perform" do
    it "threads buyer-currency quote line binding through combined-order purchase creation" do
      seller_1.update!(tipping_enabled: true)
      product_1.update!(price_currency_type: Currency::EUR, price_cents: 15_00)
      line_uid = "tz "
      params[:line_items] = [
        {
          uid: line_uid,
          permalink: product_1.unique_permalink,
          price_cents: 17_25,
          perceived_price_cents: 17_25,
          tip_cents: 2_25,
          quantity: 1,
        }
      ]
      params[:buyer_currency_quote] = signed_buyer_currency_quote(
        seller: seller_1,
        product: product_1,
        rate: "0.8571",
        canonical_components: [
          {
            "uid" => line_uid,
            "line_index" => 0,
            "permalink" => product_1.unique_permalink,
            "price_cents" => 17_50,
            "tip_cents" => 2_63,
            "seller_tax_cents" => 0,
            "gumroad_tax_cents" => 0,
            "shipping_cents" => 0,
          }
        ]
      )
      params[:payment_details_source] = "payment_element"
      params[:confirmation_token] = "ctoken_123"

      order, purchase_responses = Order::CreateService.new(params:).perform

      expect(purchase_responses).to be_empty
      purchase = order.purchases.sole
      expect(purchase.tip.value_usd_cents).to eq(2_63)
      expect(purchase.total_transaction_cents).to eq(20_13)
    end

    it "rejects carts above the product limit before allocating discounts" do
      stub_const("Cart::MAX_ALLOWED_CART_PRODUCTS", 4)
      expect(OfferCodeDiscountComputingService).not_to receive(:new)

      order, purchase_responses = Order::CreateService.new(params:).perform

      expect(order).not_to be_persisted
      expect(purchase_responses.keys).to match_array(params[:line_items].pluck(:uid))
      expect(purchase_responses.values).to all(include(
        success: false,
        error_message: "You cannot add more than 4 products to the cart."
      ))
    end

    context "with a fixed discount applied once per cart" do
      let(:offer_code) do
        create(
          :universal_offer_code,
          user: seller_1,
          amount_cents: 1_00,
          amount_percentage: nil,
          currency_type: "usd",
          once_per_cart: true
        )
      end

      before do
        product_1.update_column(:unique_permalink, "a_product")
        product_2.update_column(:unique_permalink, "b_product")
        params[:line_items] = [
          {
            uid: "unique-id-0",
            permalink: product_1.unique_permalink,
            price_cents: price_1,
            perceived_price_cents: price_1 - 1_00,
            quantity: 1,
            discount_code: offer_code.code,
          },
          {
            uid: "unique-id-1",
            permalink: product_2.unique_permalink,
            price_cents: price_2,
            perceived_price_cents: price_2,
            quantity: 1,
            discount_code: offer_code.code,
          },
        ]
      end

      it "matches the quoted allocation when building purchases" do
        order, purchase_responses = Order::CreateService.new(params:).perform

        expect(purchase_responses).to be_empty
        expect(order.purchases.order(:id).map(&:displayed_price_cents)).to eq([price_1 - 1_00, price_2])
        expect(order.purchases.order(:id).map(&:offer_code_id)).to eq([offer_code.id, nil])
        expect(order.purchases.order(:id).first.purchase_offer_code_discount.once_per_cart).to be(true)
        expect(order.purchases.order(:id).first.purchase_offer_code_discount.pre_discount_displayed_price_cents).to eq(price_1)
      end

      it "carries an amount the first line cannot absorb onto the next line" do
        product_1.update!(price_cents: 10_00)
        offer_code.update!(amount_cents: 15_00, max_purchase_count: 1)
        params[:line_items] = [
          {
            uid: "unique-id-0",
            permalink: product_1.unique_permalink,
            price_cents: 10_00,
            perceived_price_cents: 0,
            quantity: 1,
            discount_code: offer_code.code,
          },
          {
            uid: "unique-id-1",
            permalink: product_2.unique_permalink,
            price_cents: 10_00,
            perceived_price_cents: 5_00,
            quantity: 1,
            discount_code: offer_code.code,
          },
        ]

        order, purchase_responses = Order::CreateService.new(params:).perform
        purchases = order.purchases.order(:id)

        expect(purchase_responses).to be_empty
        expect(purchases.map(&:displayed_price_cents)).to eq([0, 5_00])
        expect(purchases.map(&:offer_code_id)).to eq([offer_code.id, offer_code.id])
        expect(purchases.map { _1.purchase_offer_code_discount.offer_code_amount }).to eq([10_00, 5_00])
        expect(purchases.map(&:displayed_price_cents_before_offer_code)).to eq([10_00, 10_00])
        expect(offer_code.quantity_left).to eq(0)
      end

      it "ignores client allocation hints" do
        product_1.update!(price_cents: 10_00)
        product_1.update_column(:unique_permalink, "z_product")
        product_2.update_column(:unique_permalink, "a_product")
        offer_code.update!(amount_cents: 15_00)
        params[:line_items] = [
          {
            uid: "unique-id-0",
            permalink: product_1.unique_permalink,
            price_cents: 10_00,
            perceived_price_cents: 5_00,
            quantity: 1,
            discount_code: offer_code.code,
            once_per_cart_discount_cents: 10_00,
            once_per_cart_discount_rank: 0,
          },
          {
            uid: "unique-id-1",
            permalink: product_2.unique_permalink,
            price_cents: 10_00,
            perceived_price_cents: 0,
            quantity: 1,
            discount_code: offer_code.code,
            once_per_cart_discount_cents: 5_00,
            once_per_cart_discount_rank: 1,
          },
        ]

        order, purchase_responses = Order::CreateService.new(params:).perform
        purchases = order.purchases.order(:id)

        expect(purchase_responses).to be_empty
        expect(purchases.map(&:displayed_price_cents)).to eq([5_00, 0])
        expect(purchases.map { _1.purchase_offer_code_discount.offer_code_amount }).to eq([5_00, 10_00])
      end

      it "uses the product price instead of the submitted allocation capacity" do
        product_1.update!(price_cents: 5_00)
        product_2.update!(price_cents: 20_00)
        offer_code.update!(amount_cents: 15_00)
        params[:line_items] = [
          {
            uid: "unique-id-0",
            permalink: product_1.unique_permalink,
            price_cents: 1_00,
            perceived_price_cents: 0,
            quantity: 1,
            discount_code: offer_code.code,
          },
          {
            uid: "unique-id-1",
            permalink: product_2.unique_permalink,
            price_cents: 20_00,
            perceived_price_cents: 10_00,
            quantity: 1,
            discount_code: offer_code.code,
          },
        ]

        order, purchase_responses = Order::CreateService.new(params:).perform
        purchases = order.purchases.order(:id)

        expect(purchase_responses).to be_empty
        expect(purchases.map(&:displayed_price_cents)).to eq([0, 10_00])
        expect(purchases.map { _1.purchase_offer_code_discount.offer_code_amount }).to eq([5_00, 10_00])
      end

      it "carries the amount that would leave a positive total below the currency minimum" do
        product_1.update!(price_cents: 1_00)
        offer_code.update!(amount_cents: 1_99)
        params[:line_items] = [
          {
            uid: "unique-id-0",
            permalink: product_1.unique_permalink,
            price_cents: 2_00,
            perceived_price_cents: 99,
            quantity: 2,
            discount_code: offer_code.code,
          },
          {
            uid: "unique-id-1",
            permalink: product_2.unique_permalink,
            price_cents: 10_00,
            perceived_price_cents: 9_02,
            quantity: 1,
            discount_code: offer_code.code,
          },
        ]

        order, purchase_responses = Order::CreateService.new(params:).perform
        purchases = order.purchases.order(:id)

        expect(purchase_responses).to be_empty
        expect(purchases.map(&:displayed_price_cents)).to eq([99, 9_02])
        expect(purchases.map { _1.purchase_offer_code_discount.offer_code_amount }).to eq([1_01, 98])
      end

      it "keeps the cart code identity when a later fragment is an accepted cross-sell" do
        product_1.update!(price_cents: 10_00)
        offer_code.update!(amount_cents: 15_00, max_purchase_count: 1)
        cross_sell_code = create(:offer_code, user: seller_1, products: [product_2], code: "CROSSSELL", amount_cents: 1_00,
                                              max_purchase_count: 1)
        cross_sell = create(
          :upsell,
          seller: seller_1,
          product: product_2,
          selected_products: [product_1],
          offer_code: cross_sell_code,
          cross_sell: true
        )
        params[:line_items] = [
          {
            uid: "unique-id-0",
            permalink: product_1.unique_permalink,
            price_cents: 10_00,
            perceived_price_cents: 0,
            quantity: 1,
            discount_code: offer_code.code,
          },
          {
            uid: "unique-id-1",
            permalink: product_2.unique_permalink,
            price_cents: 10_00,
            perceived_price_cents: 5_00,
            quantity: 1,
            discount_code: offer_code.code,
            accepted_offer: {
              id: cross_sell.external_id,
              original_product_id: product_1.external_id,
            },
          },
        ]

        order, purchase_responses = Order::CreateService.new(params:).perform
        purchase = order.purchases.find_by(link: product_2)

        expect(purchase_responses).to be_empty
        expect(purchase.offer_code).to eq(offer_code)
        expect(purchase.purchase_offer_code_discount.offer_code).to eq(offer_code)
        expect(cross_sell_code.quantity_left).to eq(1)
      end

      it "allocates the cart discount away from a smaller accepted-offer discount" do
        product_1.update!(price_cents: 10_00)
        offer_code.update!(amount_cents: 5_00)
        cross_sell_code = create(
          :offer_code,
          user: seller_1,
          products: [product_1],
          code: "CROSSSELL2",
          amount_cents: 2_00
        )
        cross_sell = create(
          :upsell,
          seller: seller_1,
          product: product_1,
          selected_products: [product_2],
          offer_code: cross_sell_code,
          cross_sell: true
        )
        params[:line_items] = [
          {
            uid: "unique-id-0",
            permalink: product_1.unique_permalink,
            price_cents: 10_00,
            perceived_price_cents: 8_00,
            quantity: 1,
            discount_code: offer_code.code,
            accepted_offer: {
              id: cross_sell.external_id,
              original_product_id: product_2.external_id,
            },
          },
          {
            uid: "unique-id-1",
            permalink: product_2.unique_permalink,
            price_cents: 10_00,
            perceived_price_cents: 5_00,
            quantity: 1,
            discount_code: offer_code.code,
          },
        ]

        order, purchase_responses = Order::CreateService.new(params:).perform
        purchases = order.purchases.index_by(&:link)

        expect(purchase_responses).to be_empty
        expect(purchases.fetch(product_1).displayed_price_cents).to eq(8_00)
        expect(purchases.fetch(product_1).offer_code).to eq(cross_sell_code)
        expect(purchases.fetch(product_2).displayed_price_cents).to eq(5_00)
        expect(purchases.fetch(product_2).offer_code).to eq(offer_code)
      end

      it "uses the explicit PPP preference when ordering allocations" do
        service = Order::CreateService.new(params:)

        expect(service.send(:allocations_consider_ppp?, [{ accepts_purchasing_power_parity_discount: false }])).to be(false)
        expect(service.send(:allocations_consider_ppp?, [{ accepts_purchasing_power_parity_discount: true }])).to be(true)
        expect(service.send(:allocations_consider_ppp?, [{}])).to be(true)
      end

      it "keeps capped-code usage on a surviving fragment when the first allocation fails" do
        product_1.update!(price_cents: 10_00)
        offer_code.update!(amount_cents: 15_00, max_purchase_count: 1)
        params[:line_items] = [
          {
            uid: "unique-id-0",
            permalink: product_1.unique_permalink,
            price_cents: 10_00,
            perceived_price_cents: 0,
            quantity: 1,
            variants: [create(:variant).external_id],
            discount_code: offer_code.code,
          },
          {
            uid: "unique-id-1",
            permalink: product_2.unique_permalink,
            price_cents: 10_00,
            perceived_price_cents: 5_00,
            quantity: 1,
            discount_code: offer_code.code,
          },
        ]

        order, purchase_responses = Order::CreateService.new(params:).perform
        surviving_purchase = order.purchases.find_by(link: product_2)

        expect(purchase_responses["unique-id-0"]).to include(success: false)
        expect(surviving_purchase).to be_in_progress
        expect(surviving_purchase.offer_code_id).to eq(offer_code.id)
        expect(surviving_purchase.displayed_price_cents).to eq(5_00)
        expect(surviving_purchase.purchase_offer_code_discount.offer_code_amount).to eq(5_00)
        expect(offer_code.quantity_left).to eq(0)
      end

      it "does not reprice surviving lines after checkout submission" do
        product_1.update!(price_cents: 10_00)
        offer_code.update!(amount_cents: 15_00, max_purchase_count: 1)
        params[:line_items] = [
          {
            uid: "unique-id-0",
            permalink: product_1.unique_permalink,
            price_cents: 10_00,
            perceived_price_cents: 0,
            quantity: 1,
            variants: [create(:variant).external_id],
            discount_code: offer_code.code,
          },
          {
            uid: "unique-id-1",
            permalink: product_2.unique_permalink,
            price_cents: 10_00,
            perceived_price_cents: 5_00,
            quantity: 1,
            discount_code: offer_code.code,
          },
          {
            uid: "unique-id-2",
            permalink: product_3.unique_permalink,
            price_cents: 10_00,
            perceived_price_cents: 10_00,
            quantity: 1,
          },
        ]

        order, purchase_responses = Order::CreateService.new(params:).perform
        second_purchase = order.purchases.find_by(link: product_2)
        third_purchase = order.purchases.find_by(link: product_3)

        expect(purchase_responses["unique-id-0"]).to include(success: false)
        expect(second_purchase.displayed_price_cents).to eq(5_00)
        expect(third_purchase.displayed_price_cents).to eq(10_00)
        expect(second_purchase.purchase_offer_code_discount.offer_code_amount).to eq(5_00)
        expect(third_purchase.purchase_offer_code_discount).to be_nil
        expect(second_purchase.offer_code_id).to eq(offer_code.id)
        expect(third_purchase.offer_code_id).to be_nil
        expect(offer_code.quantity_left).to eq(0)
      end

      it "restores the use when no discounted line survives" do
        product_1.update!(price_cents: 10_00)
        offer_code.update!(amount_cents: 10_00, max_purchase_count: 1)
        params[:line_items] = [
          {
            uid: "unique-id-0",
            permalink: product_1.unique_permalink,
            price_cents: 10_00,
            perceived_price_cents: 0,
            quantity: 1,
            variants: [create(:variant).external_id],
            discount_code: offer_code.code,
          },
          {
            uid: "unique-id-1",
            permalink: product_2.unique_permalink,
            price_cents: 10_00,
            perceived_price_cents: 10_00,
            quantity: 1,
          },
        ]

        order, purchase_responses = Order::CreateService.new(params:).perform
        surviving_purchase = order.purchases.find_by(link: product_2)

        expect(purchase_responses["unique-id-0"]).to include(success: false)
        expect(surviving_purchase.displayed_price_cents).to eq(10_00)
        expect(surviving_purchase.offer_code_id).to be_nil
        expect(surviving_purchase.purchase_offer_code_discount).to be_nil
        expect(offer_code.quantity_left).to eq(1)
      end

      it "rejects duplicate line item IDs before allocating the discount" do
        params[:line_items].second[:uid] = params[:line_items].first[:uid]

        expect do
          order, purchase_responses = Order::CreateService.new(params:).perform

          expect(order).not_to be_persisted
          expect(purchase_responses.values).to all(include(
            success: false,
            error_message: "The cart data is invalid. Please refresh and try again."
          ))
        end.not_to change(Purchase, :count)
      end

      it "snapshots the chosen PWYW price when the discount reaches exactly zero" do
        chosen_price = price_1 + 2_00
        product_1.update!(customizable_price: true)
        offer_code.update!(amount_cents: chosen_price)
        params[:line_items] = [{
          uid: "unique-id-0",
          permalink: product_1.unique_permalink,
          price_cents: chosen_price,
          perceived_price_cents: 0,
          quantity: 1,
          discount_code: offer_code.code,
        }]

        order, purchase_responses = Order::CreateService.new(params:).perform
        purchase = order.purchases.first

        expect(purchase_responses).to be_empty
        expect(purchase.displayed_price_cents).to eq(0)
        expect(purchase.purchase_offer_code_discount.pre_discount_displayed_price_cents).to eq(chosen_price)
        expect(purchase.displayed_price_cents_before_offer_code).to eq(chosen_price)
      end

      it "snapshots the full price for an installment payment" do
        installment_product = create(:product, user: seller_1, price_cents: 1_98)
        installment_plan = create(:product_installment_plan, link: installment_product, number_of_installments: 2)
        offer_code.update!(amount_cents: 99)
        discounted_total = installment_product.price_cents - offer_code.amount_cents
        installment_price = installment_plan.calculate_installment_payment_price_cents(discounted_total).first
        params[:line_items] = [{
          uid: "unique-id-0",
          permalink: installment_product.unique_permalink,
          price_cents: installment_product.price_cents,
          perceived_price_cents: installment_price,
          quantity: 1,
          discount_code: offer_code.code,
          pay_in_installments: true,
        }]

        order, purchase_responses = Order::CreateService.new(params:).perform
        purchase = order.purchases.first

        expect(purchase_responses).to be_empty
        expect(purchase.displayed_price_cents).to eq(installment_price)
        expect(purchase.purchase_offer_code_discount.pre_discount_displayed_price_cents).to eq(installment_product.price_cents)
        expect(purchase.displayed_price_cents_before_offer_code).to eq(installment_product.price_cents)
      end

      it "snapshots the full price for a commission deposit" do
        seller_1.update!(created_at: 31.days.ago)
        commission_product = create(:commission_product, user: seller_1, price_cents: 1_98)
        offer_code.update!(amount_cents: 99)
        discounted_total = commission_product.price_cents - offer_code.amount_cents
        discounted_deposit = discounted_total * Commission::COMMISSION_DEPOSIT_PROPORTION
        params[:line_items] = [{
          uid: "unique-id-0",
          permalink: commission_product.unique_permalink,
          price_cents: commission_product.price_cents,
          perceived_price_cents: discounted_deposit,
          quantity: 1,
          discount_code: offer_code.code,
        }]

        order, purchase_responses = Order::CreateService.new(params:).perform
        purchase = order.purchases.first
        commission = Commission.new(deposit_purchase: purchase)

        expect(purchase_responses).to be_empty
        expect(purchase.displayed_price_cents).to eq(discounted_deposit.round)
        expect(purchase.purchase_offer_code_discount.pre_discount_displayed_price_cents).to eq(commission_product.price_cents)
        expect(purchase.displayed_price_cents_before_offer_code).to eq(commission_product.price_cents)
        expect(purchase.displayed_price_cents + commission.completion_display_price_cents).to eq(discounted_total)
        expect(purchase.price_cents + commission.completion_price_cents).to eq(discounted_total)

        purchase.create_tip!(value_cents: 10, value_usd_cents: 10)
        purchase.update!(displayed_price_cents: purchase.displayed_price_cents + 10, price_cents: purchase.price_cents + 10)
        expect(purchase.displayed_price_cents + commission.completion_display_price_cents).to eq(discounted_total + 20)
        expect(purchase.price_cents + commission.completion_price_cents).to eq(discounted_total + 20)

        completion_purchase = build(
          :purchase_in_progress,
          link: commission_product,
          seller: seller_1,
          perceived_price_cents: commission.completion_display_price_cents,
          is_commission_completion_purchase: true
        )
        completion_purchase.inherit_offer_code_from(purchase)
        completion_purchase.build_tip(value_cents: 10, value_usd_cents: 10)
        completion_purchase.set_price_and_rate
        expect(completion_purchase.displayed_price_cents + completion_purchase.tip.value_cents)
          .to eq(commission.completion_display_price_cents)
      end

      it "reserves one capped use for the whole cart" do
        offer_code.update!(max_purchase_count: 1)

        order, purchase_responses = Order::CreateService.new(params:).perform

        expect(purchase_responses).to be_empty
        expect(order.purchases.order(:id).map(&:offer_code_id)).to eq([offer_code.id, nil])
        expect(offer_code.quantity_left).to eq(0)
      end

      it "deducts the fixed amount once when the winning line has multiple units" do
        params[:line_items].first.merge!(quantity: 2, perceived_price_cents: price_1 * 2 - 1_00)

        order, purchase_responses = Order::CreateService.new(params:).perform

        expect(purchase_responses).to be_empty
        expect(order.purchases.order(:id).map(&:displayed_price_cents)).to eq([price_1 * 2 - 1_00, price_2])
      end

      it "prioritizes the line that submitted the code" do
        params[:line_items].first.delete(:discount_code)
        params[:line_items].first[:perceived_price_cents] = price_1
        params[:line_items].second[:perceived_price_cents] = price_2 - 1_00

        order, purchase_responses = Order::CreateService.new(params:).perform

        expect(purchase_responses).to be_empty
        expect(order.purchases.order(:id).map(&:displayed_price_cents)).to eq([price_1, price_2 - 1_00])
        expect(order.purchases.order(:id).map(&:offer_code_id)).to eq([nil, offer_code.id])
      end

      it "allocates by line identity when two variants share a permalink" do
        offer_code.update!(minimum_quantity: 2)
        variant_category = create(:variant_category, link: product_1)
        first_variant = create(:variant, variant_category:, name: "First")
        second_variant = create(:variant, variant_category:, name: "Second")
        params[:line_items] = [
          {
            uid: "first-variant",
            permalink: product_1.unique_permalink,
            perceived_price_cents: price_1,
            quantity: 1,
            variants: [first_variant.external_id],
          },
          {
            uid: "second-variant",
            permalink: product_1.unique_permalink,
            perceived_price_cents: price_1 * 2 - 1_00,
            quantity: 2,
            variants: [second_variant.external_id],
            discount_code: offer_code.code,
          },
        ]

        order, purchase_responses = Order::CreateService.new(params:).perform

        expect(purchase_responses).to be_empty
        expect(order.purchases.order(:id).map(&:displayed_price_cents)).to eq([price_1, price_1 * 2 - 1_00])
        expect(order.purchases.order(:id).map(&:offer_code_id)).to eq([nil, offer_code.id])
      end

      it "combines variant quantities when checking the minimum" do
        offer_code.update!(minimum_quantity: 2)
        variant_category = create(:variant_category, link: product_1)
        first_variant = create(:variant, variant_category:, name: "First")
        second_variant = create(:variant, variant_category:, name: "Second")
        params[:line_items] = [first_variant, second_variant].each_with_index.map do |variant, index|
          {
            uid: "variant-#{index}",
            permalink: product_1.unique_permalink,
            price_cents: price_1,
            perceived_price_cents: index.zero? ? price_1 - 1_00 : price_1,
            quantity: 1,
            variants: [variant.external_id],
            discount_code: index.zero? ? offer_code.code : nil,
          }
        end

        order, purchase_responses = Order::CreateService.new(params:).perform

        expect(purchase_responses).to be_empty
        expect(order.purchases.order(:id).map(&:displayed_price_cents)).to eq([price_1 - 1_00, price_1])
        expect(order.purchases.order(:id).map(&:offer_code_id)).to eq([offer_code.id, nil])
      end

      it "counts a missing quantity as one when checking the minimum" do
        offer_code.update!(minimum_quantity: 1)
        params[:line_items].first.delete(:quantity)

        order, purchase_responses = Order::CreateService.new(params:).perform

        expect(purchase_responses).to be_empty
        expect(order.purchases.order(:id).map(&:displayed_price_cents)).to eq([price_1 - 1_00, price_2])
        expect(order.purchases.order(:id).map(&:offer_code_id)).to eq([offer_code.id, nil])
      end

      it "normalizes the submitted code before allocating the discount" do
        params[:line_items].each { _1[:discount_code] = " #{offer_code.code.upcase} " }

        order, purchase_responses = Order::CreateService.new(params:).perform

        expect(purchase_responses).to be_empty
        expect(order.purchases.order(:id).map(&:displayed_price_cents)).to eq([price_1 - 1_00, price_2])
        expect(order.purchases.order(:id).map(&:offer_code_id)).to eq([offer_code.id, nil])
      end

      it "uses the resolved offer code identity for equivalent spellings" do
        offer_code.update!(code: "SAVE")
        params[:line_items].first[:discount_code] = "SAVE"
        params[:line_items].second[:discount_code] = "SAVÉ"

        order, purchase_responses = Order::CreateService.new(params:).perform

        expect(purchase_responses).to be_empty
        expect(order.purchases.order(:id).map(&:displayed_price_cents)).to eq([price_1 - 1_00, price_2])
        expect(order.purchases.order(:id).map(&:offer_code_id)).to eq([offer_code.id, nil])
      end

      it "keeps separate product-scoped codes with the same text" do
        offer_code.mark_deleted!
        first_code = create(:offer_code, user: seller_1, products: [product_1], code: "SAVE", amount_cents: 1_00,
                                         amount_percentage: nil, currency_type: "usd", once_per_cart: true)
        second_code = create(:offer_code, user: seller_1, products: [product_2], code: "SAVE", amount_cents: 1_00,
                                          amount_percentage: nil, currency_type: "usd", once_per_cart: true)
        params[:line_items].each { _1[:discount_code] = "SAVE" }
        params[:line_items].second[:perceived_price_cents] -= 1_00

        order, purchase_responses = Order::CreateService.new(params:).perform

        expect(purchase_responses).to be_empty
        expect(order.purchases.order(:id).map(&:displayed_price_cents)).to eq([price_1 - 1_00, price_2 - 1_00])
        expect(order.purchases.order(:id).map(&:offer_code_id)).to eq([first_code.id, second_code.id])
      end

      it "restores code coverage for every eligible line when checkout fails" do
        product_1.update!(max_purchase_count: 1)
        product_2.update!(max_purchase_count: 1)
        params[:line_items].first.merge!(quantity: 2, perceived_price_cents: price_1 * 2 - 1_00)
        params[:line_items].second.merge!(quantity: 2, perceived_price_cents: price_2 * 2)

        _order, purchase_responses, offer_code_responses = Order::CreateService.new(params:).perform

        expect(purchase_responses.values).to all(include(success: false))
        expect(offer_code_responses.one?).to be(true)
        expect(offer_code_responses.first[:products].keys).to contain_exactly(
          product_1.unique_permalink,
          product_2.unique_permalink
        )
      end

      it "restores the code when only an unallocated line fails" do
        offer_code.update!(max_purchase_count: 1)
        product_2.update!(max_purchase_count: 1)
        params[:line_items].second.merge!(quantity: 2, perceived_price_cents: price_2 * 2)

        order, purchase_responses, offer_code_responses = Order::CreateService.new(params:).perform

        expect(order.purchases.first).to be_in_progress
        expect(purchase_responses.values.one?).to be(true)
        expect(purchase_responses.values.first).to include(success: false)
        expect(offer_code_responses.one?).to be(true)
        expect(offer_code_responses.first[:products].keys).to contain_exactly(
          product_1.unique_permalink,
          product_2.unique_permalink
        )
      end

      it "restores coverage when an unallocated line fails before persistence" do
        params[:line_items].second.delete(:discount_code)
        params[:line_items].second[:variants] = [create(:variant).external_id]

        order, purchase_responses, offer_code_responses = Order::CreateService.new(params:).perform

        expect(order.purchases.one?).to be(true)
        expect(purchase_responses.values.one?).to be(true)
        expect(purchase_responses.values.first).to include(success: false)
        expect(offer_code_responses.one?).to be(true)
        expect(offer_code_responses.first[:products].keys).to contain_exactly(
          product_1.unique_permalink,
          product_2.unique_permalink
        )
      end

      it "restores every covered line when purchase creation fails before persistence" do
        params[:line_items].each { _1[:discount_code] = " #{offer_code.code.upcase} " }
        failed_service = instance_double(Purchase::CreateService, perform: [nil, "Invalid purchase", nil])
        allow(Purchase::CreateService).to receive(:new).and_return(failed_service)

        order, purchase_responses, offer_code_responses = Order::CreateService.new(params:).perform

        expect(order).not_to be_persisted
        expect(purchase_responses.values).to all(include(success: false))
        expect(offer_code_responses.one?).to be(true)
        expect(offer_code_responses.first[:products].keys).to contain_exactly(
          product_1.unique_permalink,
          product_2.unique_permalink
        )
      end
    end

    it "creates an order along with the associated purchases in progress" do
      expect do
        expect do
          expect do
            order, _ = Order::CreateService.new(params:).perform

            expect(order.purchases.in_progress.count).to eq 5
          end.to change { Order.count }.by 1
        end.not_to change { Charge.count }
      end.to change { Purchase.count }.by 5
    end

    it "calls Purchase::CreateService for all line items in params with is_part_of_combined_charge set to true" do
      params[:line_items].each do |line_item_params|
        expect(Purchase::CreateService).to receive(:new).with(product: Link.find_by(unique_permalink: line_item_params[:permalink]),
                                                              params: hash_including(is_part_of_combined_charge: true),
                                                              buyer: nil).and_call_original
      end

      order, _ = Order::CreateService.new(params:).perform

      expect(order.purchases.in_progress.count).to eq 5
      expect(order.purchases.is_part_of_combined_charge.count).to eq 5
    end

    it "sets all the common fields on all purchases correctly" do
      order, _ = Order::CreateService.new(params:).perform

      expect(order.purchases.in_progress.count).to eq 5
      expect(order.purchases.pluck(:email).uniq).to eq([common_order_params_without_payment[:email]])
      expect(order.purchases.pluck(:browser_guid).uniq).to eq([common_order_params_without_payment[:browser_guid]])
      expect(order.purchases.pluck(:session_id).uniq).to eq([common_order_params_without_payment[:session_id]])
      expect(order.purchases.pluck(:is_mobile).uniq).to eq([common_order_params_without_payment[:is_mobile]])
      expect(order.purchases.pluck(:ip_address).uniq).to eq([common_order_params_without_payment[:ip_address]])
      expect(order.purchases.pluck(:full_name).uniq).to eq([common_order_params_without_payment[:purchase][:full_name]])
      expect(order.purchases.pluck(:street_address).uniq).to eq([common_order_params_without_payment[:purchase][:street_address]])
      expect(order.purchases.pluck(:state).uniq).to eq([common_order_params_without_payment[:purchase][:state]])
      expect(order.purchases.pluck(:city).uniq).to eq([common_order_params_without_payment[:purchase][:city]])
      expect(order.purchases.pluck(:zip_code).uniq).to eq([common_order_params_without_payment[:purchase][:zip_code]])
    end

    it "sets the buyer when provided" do
      buyer = create(:user, email: "buyer@gumroad.com")

      order, _ = Order::CreateService.new(params:, buyer:).perform

      expect(order.purchaser).to eq buyer
    end

    describe "recording the payment flow" do
      # The flow is recorded before the charge, so stub charging to keep these recording-focused
      # specs off Stripe while still exercising real submitted payment params.
      before { allow_any_instance_of(Purchase).to receive(:charge!) }

      it "records the Payment Element surface on every purchase in the order" do
        params[:payment_details_source] = "payment_element"
        params[:stripe_payment_method_id] = "pm_123"

        order, _ = Order::CreateService.new(params:).perform

        flows = order.reload.purchases.map(&:purchase_payment_flow)
        expect(flows.size).to eq(5)
        expect(flows).to all(be_present)
        expect(flows.map(&:payment_details_source).uniq).to eq(["payment_element"])
        expect(flows.map(&:payment_details_transport).uniq).to eq(["payment_method"])
        expect(flows.map(&:stripe_payment_method_type).uniq).to eq(["card"])
      end

      it "records the CardElement surface when the client reports it" do
        params[:payment_details_source] = "card_element"
        params[:stripe_payment_method_id] = "pm_123"

        order, _ = Order::CreateService.new(params:).perform

        expect(order.reload.purchases.map { _1.purchase_payment_flow.payment_details_source }.uniq).to eq(["card_element"])
      end

      it "records the confirmation_token transport for a client-confirm submission" do
        params[:payment_details_source] = "payment_element"
        params[:confirmation_token] = "ctoken_123"

        order, _ = Order::CreateService.new(params:).perform

        flows = order.reload.purchases.map(&:purchase_payment_flow)
        expect(flows.size).to eq(5)
        expect(flows).to all(be_present)
        expect(flows.map(&:payment_details_source).uniq).to eq(["payment_element"])
        expect(flows.map(&:payment_details_transport).uniq).to eq(["confirmation_token"])
        expect(flows.map(&:stripe_payment_method_type).uniq).to eq(["card"])
      end

      it "builds purchases when the client reports the element's mount currency (not a Purchase attribute)" do
        params[:payment_details_source] = "payment_element"
        params[:confirmation_token] = "ctoken_123"
        params[:payment_element_mount_currency] = "eur"

        order, _ = Order::CreateService.new(params:).perform

        expect(order.reload.purchases.size).to eq(5)
      end

      it "records a wallet payment through the Payment Element as a payment_element purchase" do
        # A wallet PaymentMethod submitted by the Payment Element carries both the wallet marker
        # and the element's source hint; it must be attributed to the element surface, not the
        # Payment Request Button (antiwork/gumroad#5768).
        params[:wallet_type] = "apple_pay"
        params[:payment_details_source] = "payment_element"
        params[:stripe_payment_method_id] = "pm_123"

        order, _ = Order::CreateService.new(params:).perform

        expect(order.reload.purchases.map { _1.purchase_payment_flow.payment_details_source }.uniq).to eq(["payment_element"])
      end

      it "records a wallet payment without an element source hint as a payment request" do
        # The Payment Request Button sends wallet_type with no payment_details_source param —
        # that shape stays attributed to the button.
        params[:wallet_type] = "apple_pay"
        params[:stripe_payment_method_id] = "pm_123"

        order, _ = Order::CreateService.new(params:).perform

        expect(order.reload.purchases.map { _1.purchase_payment_flow.payment_details_source }.uniq).to eq(["payment_request"])
      end

      it "does not record a payment flow when no Stripe surface is reported" do
        order, _ = Order::CreateService.new(params:).perform

        expect(order.reload.purchases.map(&:purchase_payment_flow)).to all(be_nil)
      end

      it "does not record a Stripe flow for a non-Stripe (PayPal) submission even with a forged source hint" do
        params[:payment_details_source] = "payment_element"
        params[:paypal_order_id] = "PAY-123"

        order, _ = Order::CreateService.new(params:).perform

        expect(order.reload.purchases.map(&:purchase_payment_flow)).to all(be_nil)
      end

      it "does not abort the purchase when recording the payment flow raises a duplicate, without reporting it" do
        params[:payment_details_source] = "payment_element"
        params[:stripe_payment_method_id] = "pm_123"
        allow_any_instance_of(Purchase).to receive(:create_purchase_payment_flow).and_raise(ActiveRecord::RecordNotUnique)
        allow(Rails.logger).to receive(:error).and_call_original
        expect(ErrorNotifier).not_to receive(:notify)

        order = nil
        expect do
          order, _ = Order::CreateService.new(params:).perform
        end.to change { Purchase.count }.by(5)

        expect(order.reload.purchases.in_progress.count).to eq(5)
        expect(Rails.logger).to have_received(:error).with(/Error recording purchase payment flow/).at_least(:once)
      end

      it "reports an unexpected recording error without aborting the purchase" do
        params[:payment_details_source] = "payment_element"
        params[:stripe_payment_method_id] = "pm_123"
        allow_any_instance_of(Purchase).to receive(:create_purchase_payment_flow).and_raise(StandardError.new("boom"))
        expect(ErrorNotifier).to receive(:notify).at_least(:once)

        expect do
          Order::CreateService.new(params:).perform
        end.to change { Purchase.count }.by(5)
      end

      it "records the paid purchases but not a free purchase in the same cart" do
        free_product = create(:product, user: seller_1, price_cents: 0)
        params[:payment_details_source] = "payment_element"
        params[:stripe_payment_method_id] = "pm_123"
        params[:line_items] << {
          uid: "unique-id-free",
          permalink: free_product.unique_permalink,
          perceived_price_cents: 0,
          quantity: 1
        }

        order, _ = Order::CreateService.new(params:).perform

        order.reload
        free_purchase = order.purchases.find_by(link_id: free_product.id)
        paid_purchases = order.purchases.where.not(link_id: free_product.id)
        expect(free_purchase.purchase_payment_flow).to be_nil
        expect(paid_purchases.map { _1.purchase_payment_flow.payment_details_source }.uniq).to eq(["payment_element"])
      end
    end

    it_behaves_like "order association with cart post checkout" do
      let(:user) { create(:buyer_user) }
      let(:sign_in_user_action) { @signed_in = true }
      let(:call_action) { Order::CreateService.new(params:, buyer: @signed_in ? user : nil).perform }
      let(:browser_guid) { "123" }

      before do
        params[:browser_guid] = browser_guid
      end
    end

    it "saves the referrer info correctly" do
      params[:line_items][0][:referrer] = "https://facebook.com"
      params[:line_items][1][:referrer] = "https://google.com"

      order, _ = Order::CreateService.new(params:).perform

      expect(order.purchases.first.referrer).to eq "https://facebook.com"
      expect(order.purchases.second.referrer).to eq "https://google.com"
    end

    it "returns failure responses with correct errors for purchases that fail" do
      product_2.update!(max_purchase_count: 2)
      params[:line_items][1][:quantity] = 3
      params[:line_items][3][:permalink] = "non-existent"

      order, purchase_responses, _ = Order::CreateService.new(params:).perform

      expect(order.purchases.count).to eq(4)
      expect(order.purchases.in_progress.count).to eq(3)
      expect(order.purchases.failed.count).to eq(1)

      expect(purchase_responses.size).to eq(2)
      expect(purchase_responses[params[:line_items][1][:uid]]).to include(
                                                                    success: false,
                                                                    error_message: "You have chosen a quantity that exceeds what is available.",
                                                                    name: "The Works of Edgar Gumstein",
                                                                    error_code: "exceeding_product_quantity")
      expect(purchase_responses[params[:line_items][3][:uid]]).to include(
                                                                    success: false,
                                                                    error_message: "Product not found",
                                                                    name: nil,
                                                                    error_code: nil)
    end

    it "does not delete the cart when all line items fail" do
      failed_params = {
        line_items: [
          { uid: "unique-id-0", permalink: "non-existent", perceived_price_cents: 500, quantity: 1 },
          { uid: "unique-id-1", permalink: "also-non-existent", perceived_price_cents: 500, quantity: 1 }
        ]
      }.merge(common_order_params_without_payment)

      buyer = create(:user, email: "buyer@gumroad.com")
      cart = create(:cart, user: buyer, browser_guid:)

      order, purchase_responses, _ = Order::CreateService.new(params: failed_params, buyer:).perform

      expect(order).not_to be_persisted
      expect(purchase_responses.values).to all(include(success: false))
      expect(cart.reload).to be_alive
    end

    # The example above only covers failures so early that no purchase row is ever written, which
    # leaves the order unpersisted. The everyday failure — a real product the buyer cannot actually
    # be sold — does write a failed purchase row, and appending that row to the order persists the
    # order. The cart cleanup used to key off `order.persisted?` alone, so a checkout where nothing
    # at all was bought still had its cart destroyed, and the buyer landed back on an empty checkout
    # with no way to retry short of re-adding every item by hand.
    #
    # Every line item here exceeds its product's remaining stock, which is the same mechanism the
    # "returns failure responses with correct errors" example above relies on to produce a persisted
    # failed purchase — so this is the real service path, not a stubbed one.
    it "keeps the cart when every line item is attempted and fails" do
      buyer = create(:user, email: "buyer@gumroad.com")
      cart = create(:cart, user: buyer, browser_guid:)

      [product_1, product_2, product_3, product_4, product_5].each do |product|
        product.update!(max_purchase_count: 1)
      end
      params[:line_items].each { _1[:quantity] = 2 }

      order, purchase_responses, _ = Order::CreateService.new(params:, buyer:).perform

      # The failed attempts are recorded, which is what persists the order...
      expect(order).to be_persisted
      expect(order.purchases).to be_present
      expect(order.purchases.map(&:purchase_state).uniq).to eq(["failed"])
      expect(purchase_responses.values).to all(include(success: false))

      # ...but nothing was bought, so the buyer keeps their cart and can retry.
      expect(cart.reload).to be_alive
      # The order is still linked, so the failed attempt stays traceable to the cart it came from.
      expect(cart.order).to eq(order)
    end

    it "creates an order along with the associated purchases in progress when merchant account is a Brazilian Stripe Connect account" do
      seller_2.update!(check_merchant_account_is_linked: true)
      create(:merchant_account_stripe_connect, charge_processor_merchant_id: "acct_1QADdCGy0w4tFIUe", country: "BR", user: seller_2)

      expect do
        expect do
          expect do
            order, _ = Order::CreateService.new(params:).perform

            expect(order.purchases.in_progress.count).to eq 5
          end.to change { Order.count }.by 1
        end.not_to change { Charge.count }
      end.to change { Purchase.count }.by 5
    end

    context "when a line item has a restartable subscription" do
      let(:membership_product) { create(:membership_product, user: seller_1, price_cents: price_1) }
      let(:buyer) { create(:user, email: "buyer@gumroad.com") }
      let!(:subscription) do
        sub = create(:subscription, link: membership_product, user: buyer)
        create(:purchase,
               link: membership_product,
               purchaser: buyer,
               email: buyer.email,
               subscription: sub,
               is_original_subscription_purchase: true,
               price_cents: membership_product.price_cents,
               variant_attributes: membership_product.tiers.to_a
        )
        sub.update!(cancelled_at: 1.day.ago, cancelled_by_buyer: true, deactivated_at: 1.day.ago)
        sub
      end

      let(:params_with_membership) do
        {
          line_items: [
            {
              uid: "unique-id-0",
              permalink: membership_product.unique_permalink,
              perceived_price_cents: membership_product.price_cents,
              quantity: 1,
              price_id: membership_product.prices.alive.first.external_id
            },
            {
              uid: "unique-id-1",
              permalink: product_2.unique_permalink,
              perceived_price_cents: product_2.price_cents,
              quantity: 1
            }
          ]
        }.merge(common_order_params_without_payment)
      end

      it "treats submitted checkout payment data as a new card during subscription restart in a multi-seller cart" do
        multi_seller_params = {
          line_items: [
            {
              uid: "unique-id-0",
              permalink: membership_product.unique_permalink,
              perceived_price_cents: membership_product.price_cents,
              quantity: 1,
              price_id: membership_product.prices.alive.first.external_id
            },
            {
              uid: "unique-id-1",
              permalink: product_4.unique_permalink,
              perceived_price_cents: product_4.price_cents,
              quantity: 1
            }
          ],
          stripe_payment_method_id: "pm_123",
          stripe_customer_id: "cus_123",
          stripe_setup_intent_id: "seti_123"
        }.merge(common_order_params_without_payment)

        updater_service = instance_double(Subscription::UpdaterService)
        expect(Subscription::UpdaterService).to receive(:new).with(
          subscription: subscription,
          params: hash_including(
            use_existing_card: false,
            stripe_customer_id: "cus_123",
            stripe_setup_intent_id: "seti_123",
            stripe_payment_method_id: "pm_123"
          ),
          logged_in_user: buyer,
          gumroad_guid: browser_guid,
          remote_ip: anything
        ).and_return(updater_service)
        allow(updater_service).to receive(:perform).and_return({ success: true, success_message: "Membership restarted" })

        order, purchase_responses, _ = Order::CreateService.new(
          params: ActionController::Parameters.new(multi_seller_params).permit!,
          buyer:
        ).perform

        expect(purchase_responses["unique-id-0"]).to include(success: true)
        # The regular product from seller_2 should still be in the order
        expect(order.purchases.in_progress.count).to eq(1)
        expect(order.purchases.first.link).to eq(product_4)
      end

      it "does not add the restarted subscription's original purchase to the order" do
        updater_service = instance_double(Subscription::UpdaterService)
        allow(Subscription::UpdaterService).to receive(:new).and_return(updater_service)
        allow(updater_service).to receive(:perform).and_return({ success: true, success_message: "Membership restarted" })

        order, purchase_responses, _ = Order::CreateService.new(params: params_with_membership, buyer:).perform

        # The restarted subscription's purchase should NOT be in the order
        expect(order.purchases.map(&:id)).not_to include(subscription.original_purchase.id)
        # But we should have a success response for the membership line item
        expect(purchase_responses["unique-id-0"]).to include(success: true)
        # The regular product should still be in the order
        expect(order.purchases.in_progress.count).to eq(1)
      end

      it "includes the regular purchase in the order" do
        updater_service = instance_double(Subscription::UpdaterService)
        allow(Subscription::UpdaterService).to receive(:new).and_return(updater_service)
        allow(updater_service).to receive(:perform).and_return({ success: true, success_message: "Membership restarted" })

        order, _, _ = Order::CreateService.new(params: params_with_membership, buyer:).perform

        expect(order.purchases.count).to eq(1)
        expect(order.purchases.first.link).to eq(product_2)
      end

      it "passes through SCA data when the restart requires card action" do
        merchant_account = create(:merchant_account_stripe_connect, user: membership_product.user)

        upgrade_purchase = create(:purchase_in_progress,
                                  link: membership_product,
                                  purchaser: buyer,
                                  email: buyer.email,
                                  subscription: subscription,
                                  price_cents: membership_product.price_cents)

        updater_service = instance_double(Subscription::UpdaterService)
        allow(Subscription::UpdaterService).to receive(:new).and_return(updater_service)
        allow(updater_service).to receive(:perform).and_return({
                                                                 success: true,
                                                                 requires_card_action: true,
                                                                 client_secret: "pi_123_secret_456",
                                                                 purchase: { id: upgrade_purchase.secure_external_id(scope: "confirm", expires_at: 1.hour.from_now), stripe_connect_account_id: merchant_account.charge_processor_merchant_id }
                                                               })

        order, purchase_responses, _ = Order::CreateService.new(params: params_with_membership, buyer:).perform

        sca_response = purchase_responses["unique-id-0"]
        expect(sca_response).to include(
          requires_card_action: true,
          client_secret: "pi_123_secret_456"
        )
        expect(Order.find_by_secure_external_id(sca_response[:order][:id], scope: "confirm")).to eq(order)
        expect(sca_response[:order][:stripe_connect_account_id]).to eq(merchant_account.charge_processor_merchant_id)
        # The SCA upgrade purchase is added to the order for the confirm endpoint
        expect(order.purchases.in_progress.count).to eq(2)
        expect(order.purchases.in_progress.map(&:link)).to include(membership_product, product_2)
      end

      it "SCA response can be confirmed via Purchase::ConfirmService" do
        # Simulate the state after UpdaterService ran: subscription alive but pending SCA confirmation
        subscription.update!(cancelled_at: nil, deactivated_at: nil)
        subscription.update_flag!(:cancelled_by_buyer, false, true)
        subscription.update_flag!(:is_resubscription_pending_confirmation, true, true)

        upgrade_purchase = create(:purchase_in_progress,
                                  link: membership_product,
                                  purchaser: buyer,
                                  email: buyer.email,
                                  subscription: subscription,
                                  price_cents: membership_product.price_cents)

        allow(upgrade_purchase).to receive(:confirm_charge_intent!)

        error = Purchase::ConfirmService.new(purchase: upgrade_purchase, params: {}).perform

        expect(error).to be_nil
        expect(upgrade_purchase.reload).to be_successful
        expect(subscription.reload).not_to be_is_resubscription_pending_confirmation
      end

      it "cleans up the cart when all line items are subscription restarts" do
        restart_only_params = {
          line_items: [
            {
              uid: "unique-id-0",
              permalink: membership_product.unique_permalink,
              perceived_price_cents: membership_product.price_cents,
              quantity: 1,
              price_id: membership_product.prices.alive.first.external_id
            }
          ]
        }.merge(common_order_params_without_payment)

        cart = create(:cart, user: buyer, browser_guid:)

        updater_service = instance_double(Subscription::UpdaterService)
        allow(Subscription::UpdaterService).to receive(:new).and_return(updater_service)
        allow(updater_service).to receive(:perform).and_return({ success: true, success_message: "Membership restarted" })

        order, purchase_responses, _ = Order::CreateService.new(params: restart_only_params, buyer:).perform

        expect(order).not_to be_persisted
        expect(purchase_responses["unique-id-0"]).to include(success: true)
        expect(cart.reload).to be_deleted
      end
    end

    context "when a line item has an active subscription" do
      let(:membership_product) { create(:membership_product, user: seller_1, price_cents: price_1) }
      let(:buyer) { create(:user, email: "buyer@gumroad.com") }
      let!(:subscription) do
        sub = create(:subscription, link: membership_product, user: buyer)
        create(:purchase,
               link: membership_product,
               purchaser: buyer,
               email: buyer.email,
               subscription: sub,
               is_original_subscription_purchase: true,
               price_cents: membership_product.price_cents,
               variant_attributes: membership_product.tiers.to_a
        )
        sub
      end

      let(:params_with_active_membership) do
        {
          line_items: [
            {
              uid: "unique-id-0",
              permalink: membership_product.unique_permalink,
              perceived_price_cents: membership_product.price_cents,
              quantity: 1,
              price_id: membership_product.prices.alive.first.external_id
            },
            {
              uid: "unique-id-1",
              permalink: product_2.unique_permalink,
              perceived_price_cents: product_2.price_cents,
              quantity: 1
            }
          ]
        }.merge(common_order_params_without_payment)
      end

      it "returns an error for the membership line item" do
        order, purchase_responses, _ = Order::CreateService.new(params: params_with_active_membership, buyer:).perform

        expect(purchase_responses["unique-id-0"]).to include(success: false)
        # The regular product should still be in the order
        expect(order.purchases.in_progress.count).to eq(1)
      end
    end
  end
end
