# frozen_string_literal: true

require "spec_helper"

describe OfferCodeDiscountComputingService do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 2000, price_currency_type: "usd") }
  let(:product2) { create(:product, user: seller, price_cents: 2000, price_currency_type: "usd") }
  let(:universal_offer_code) { create(:universal_offer_code, user: seller, amount_percentage: 100, amount_cents: nil, currency_type: product.price_currency_type) }
  let(:offer_code) { create(:offer_code, user: seller, products: [product], amount_percentage: 100, amount_cents: nil, currency_type: product.price_currency_type) }
  let(:zero_percent_discount_code) { create(:offer_code, user: seller, products: [product], amount_percentage: 0, amount_cents: nil, currency_type: product.price_currency_type) }
  let(:zero_cents_discount_code) { create(:offer_code, user: seller, products: [product], amount_percentage: nil, amount_cents: 0, currency_type: product.price_currency_type) }
  let(:products_data) do
    {
      product.unique_permalink => { quantity: "3", permalink: product.unique_permalink },
      product2.unique_permalink => { quantity: "2", permalink: product2.unique_permalink }
    }
  end

  it "returns invalid error_code in result when offer code is invalid" do
    result = OfferCodeDiscountComputingService.new("invalid_offer_code", products_data).process

    expect(result[:error_code]).to eq(:invalid_offer)
  end

  it "does not return an invalid error_code in result when offer code amount is 0 cents" do
    result = OfferCodeDiscountComputingService.new(zero_cents_discount_code.code, products_data).process

    expect(result[:error_code]).to be_nil
  end

  it "does not return an invalid error_code in result when offer code amount is 0%" do
    result = OfferCodeDiscountComputingService.new(zero_percent_discount_code.code, products_data).process

    expect(result[:error_code]).to be_nil
  end

  it "returns sold_out error_code in result when offer code is sold out" do
    universal_offer_code.update_attribute(:max_purchase_count, 0)
    result = OfferCodeDiscountComputingService.new(universal_offer_code.code, products_data).process

    expect(result[:error_code]).to eq(:sold_out)
  end

  it "applies offer code on multiple products when offer code is universal" do
    result = OfferCodeDiscountComputingService.new(universal_offer_code.code, products_data).process

    expect(result[:products_data]).to eq(
      product.unique_permalink => {
        discount: {
          type: "percent",
          percents: universal_offer_code.amount,
          product_ids: nil,
          expires_at: nil,
          minimum_quantity: nil,
          duration_in_billing_cycles: nil,
          minimum_amount_cents: nil,
        },
      },
      product2.unique_permalink => {
        discount: {
          type: "percent",
          percents: universal_offer_code.amount,
          product_ids: nil,
          expires_at: nil,
          minimum_quantity: nil,
          duration_in_billing_cycles: nil,
          minimum_amount_cents: nil,
        },
      },
    )
    expect(result[:error_code]).to eq(nil)
  end

  it "rejects product with quantity greater than the offer code limit when offer code is universal" do
    universal_offer_code.update_attribute(:max_purchase_count, 2)
    result = OfferCodeDiscountComputingService.new(universal_offer_code.code, products_data).process

    expect(result[:products_data]).to eq(
      product2.unique_permalink => {
        discount: {
          type: "percent",
          percents: universal_offer_code.amount,
          product_ids: nil,
          expires_at: nil,
          minimum_quantity: nil,
          duration_in_billing_cycles: nil,
          minimum_amount_cents: nil,
        },
      },
    )
  end

  it "applies offer code on single product in bundle when offer code is not universal" do
    result = OfferCodeDiscountComputingService.new(offer_code.code, products_data).process

    expect(result[:products_data]).to eq(
      product.unique_permalink => {
        discount: {
          type: "percent",
          percents: offer_code.amount,
          product_ids: [product.external_id],
          expires_at: nil,
          minimum_quantity: nil,
          duration_in_billing_cycles: nil,
          minimum_amount_cents: nil,
        },
      },
    )
    expect(result[:error_code]).to eq(nil)
  end

  it "includes the expiration date in the result" do
    offer_code.update!(valid_at: 1.day.ago, expires_at: 1.day.from_now)
    result = OfferCodeDiscountComputingService.new(offer_code.code, products_data).process

    expect(result[:products_data]).to eq(
      product.unique_permalink => {
        discount: {
          type: "percent",
          percents: offer_code.amount,
          product_ids: [product.external_id],
          expires_at: offer_code.expires_at,
          minimum_quantity: nil,
          duration_in_billing_cycles: nil,
          minimum_amount_cents: nil,
        },
      },
    )
    expect(result[:error_code]).to eq(nil)
  end

  it "includes the minimum quantity in the result" do
    offer_code.update!(minimum_quantity: 2)
    result = OfferCodeDiscountComputingService.new(offer_code.code, products_data).process

    expect(result[:products_data]).to eq(
      product.unique_permalink => {
        discount: {
          type: "percent",
          percents: offer_code.amount,
          product_ids: [product.external_id],
          expires_at: offer_code.expires_at,
          minimum_quantity: 2,
          duration_in_billing_cycles: nil,
          minimum_amount_cents: nil,
        },
      },
    )
    expect(result[:error_code]).to eq(nil)
  end

  it "includes the duration in the result" do
    offer_code.update!(duration_in_billing_cycles: 1)
    result = OfferCodeDiscountComputingService.new(offer_code.code, products_data).process

    expect(result[:products_data]).to eq(
      product.unique_permalink => {
        discount: {
          type: "percent",
          percents: offer_code.amount,
          product_ids: [product.external_id],
          expires_at: offer_code.expires_at,
          minimum_quantity: nil,
          duration_in_billing_cycles: 1,
          minimum_amount_cents: nil,
        },
      },
    )
    expect(result[:error_code]).to eq(nil)
  end

  it "rejects product with quantity greater than the offer code limit when offer code is not universal" do
    offer_code.update_attribute(:max_purchase_count, 2)
    result = OfferCodeDiscountComputingService.new(offer_code.code, products_data).process

    expect(result[:products_data]).to eq({})
    expect(result[:error_code]).to eq(:insufficient_times_of_use)
  end

  context "when offer code is not yet valid" do
    before do
      offer_code.update!(valid_at: 1.years.from_now)
    end

    it "returns inactive error code" do
      result = OfferCodeDiscountComputingService.new(offer_code.code, products_data).process

      expect(result[:error_code]).to eq(:inactive)
      expect(result[:products_data]).to eq({})
    end
  end

  context "when the user has multiple offer codes with the same name" do
    let(:shared_code_name) { "MULTIPRODUCT" }
    let!(:offer_code_for_product1) do
      create(
        :offer_code,
        user: seller,
        code: shared_code_name,
        products: [product],
        amount_percentage: 30,
        amount_cents: nil,
        currency_type: product.price_currency_type
      )
    end
    let!(:offer_code_for_product2) do
      create(
        :offer_code,
        user: seller,
        code: shared_code_name,
        products: [product2],
        amount_percentage: 50,
        amount_cents: nil,
        currency_type: product2.price_currency_type
        )
    end

    it "applies the correct offer code to each product based on product applicability" do
      result = OfferCodeDiscountComputingService.new(shared_code_name, products_data).process

      expect(result[:products_data]).to eq(
        product.unique_permalink => {
          discount: {
            product_ids: [product.external_id],
            **offer_code_for_product1.discount,
          },
        },
        product2.unique_permalink => {
          discount: {
            product_ids: [product2.external_id],
            **offer_code_for_product2.discount,
          },
        },
      )
      expect(result[:error_code]).to be_nil
    end
  end

  context "when the code exists but doesn't apply to this product" do
    let!(:offer_code_for_product2) do
      create(
        :offer_code,
        user: seller,
        code: "PRODUCT2",
        products: [product2],
        amount_percentage: 30,
        amount_cents: nil,
        currency_type: product.price_currency_type
      )
    end

    it "returns no discount" do
      result = OfferCodeDiscountComputingService
        .new(offer_code_for_product2.code, {
               product.unique_permalink => { quantity: "3", permalink: product.unique_permalink },
             })
        .process

      expect(result).to eq(error_code: :invalid_offer, products_data: {})
    end
  end

  context "when offer code is expired" do
    before do
      offer_code.update!(valid_at: 2.years.ago, expires_at: 1.year.ago)
    end

    it "returns inactive error code" do
      result = OfferCodeDiscountComputingService.new(offer_code.code, products_data).process

      expect(result[:error_code]).to eq(:inactive)
      expect(result[:products_data]).to eq({})
    end
  end

  context "when an offer code's minimum quantity is unmet" do
    before do
      offer_code.update!(minimum_quantity: 5)
    end

    it "returns insufficient quantity error code" do
      result = OfferCodeDiscountComputingService.new(offer_code.code, products_data).process

      expect(result[:error_code]).to eq(:unmet_minimum_purchase_quantity)
      expect(result[:products_data]).to eq({})
    end
  end

  context "when product has cross-sells" do
    let(:cross_sell_product1) { create(:product, user: seller, price_cents: 3000) }
    let(:cross_sell_product2) { create(:product, user: seller, price_cents: 4000) }
    let(:additive_cross_sell_product) { create(:product, user: seller, price_cents: 5000) }
    let!(:replacement_cross_sell1) do
      create(:upsell,
             seller: seller,
             product: cross_sell_product1,
             cross_sell: true,
             replace_selected_products: true,
             selected_products: [product]
      )
    end
    let!(:replacement_cross_sell2) do
      create(:upsell,
             seller: seller,
             product: cross_sell_product2,
             cross_sell: true,
             replace_selected_products: true,
             selected_products: [product]
      )
    end
    let!(:additive_cross_sell) do
      create(:upsell,
             seller: seller,
             product: additive_cross_sell_product,
             cross_sell: true,
             replace_selected_products: false,
             selected_products: [product]
      )
    end

    context "universal offer code" do
      let(:universal_offer_code_for_cross_sells) { create(:universal_offer_code, user: seller, amount_percentage: 50, amount_cents: nil, currency_type: "usd") }

      it "applies discount to main product and all applicable cross-sells" do
        result = OfferCodeDiscountComputingService.new(universal_offer_code_for_cross_sells.code, products_data).process

        expect(result[:products_data]).to include(
          product.unique_permalink => {
            discount: hash_including(
              type: "percent",
              percents: 50
            )
          },
          cross_sell_product1.unique_permalink => {
            discount: hash_including(
              type: "percent",
              percents: 50
            )
          },
          cross_sell_product2.unique_permalink => {
            discount: hash_including(
              type: "percent",
              percents: 50
            )
          }
        )
        expect(result[:products_data]).to include(
          additive_cross_sell.product.unique_permalink => {
            discount: hash_including(
              type: "percent",
              percents: 50
            )
          }
        )
        expect(result[:error_code]).to be_nil
      end
    end

    context "product-specific offer code" do
      let(:shared_code_name) { "SHAREDCODE" }
      let!(:offer_for_product) do
        create(
          :offer_code,
          user: seller,
          code: shared_code_name,
          products: [product],
          amount_percentage: 25,
          amount_cents: nil,
          currency_type: "usd"
        )
      end
      let!(:offer_for_cross_sell1) do
        create(
          :offer_code,
          user: seller,
          code: shared_code_name,
          products: [cross_sell_product1],
          amount_percentage: 50,
          amount_cents: nil,
          currency_type: "usd"
        )
      end

      it "applies corresponding offer code to applicable products including cross-sells" do
        result = OfferCodeDiscountComputingService.new(shared_code_name, products_data).process

        expect(result[:products_data]).to include(
          product.unique_permalink => {
            discount: hash_including(
              type: "percent",
              percents: 25
            )
          },
          cross_sell_product1.unique_permalink => {
            discount: hash_including(
              type: "percent",
              percents: 50
            )
          }
        )
        expect(result[:products_data]).not_to include(cross_sell_product2.unique_permalink)
        expect(result[:products_data]).not_to include(additive_cross_sell_product.unique_permalink)
        expect(result[:error_code]).to be_nil
      end
    end

    context "existing-customer-only cross-sell offer code" do
      let(:shared_code_name) { "EXISTINGCROSS" }
      let(:buyer) { create(:user) }
      let(:owned_product) { create(:product, user: seller) }
      let!(:offer_for_product) do
        create(
          :offer_code,
          user: seller,
          code: shared_code_name,
          products: [product],
          amount_percentage: 25,
          amount_cents: nil,
          currency_type: "usd"
        )
      end

      it "uses the buyer-resolved tier discount for applicable cross-sells" do
        create(:purchase, purchaser: buyer, link: owned_product, seller:, price_cents: owned_product.price_cents, created_at: 13.months.ago)
        create(
          :offer_code,
          user: seller,
          code: shared_code_name,
          products: [cross_sell_product1],
          ownership_products: [owned_product],
          existing_customers_only: true,
          amount_cents: nil,
          amount_percentage: 0,
          currency_type: nil,
          ownership_duration_tiers: [
            { "months" => 0, "amount_percentage" => 0 },
            { "months" => 12, "amount_percentage" => 50 },
          ]
        )

        result = OfferCodeDiscountComputingService.new(shared_code_name, products_data, buyer:).process

        expect(result[:products_data][product.unique_permalink][:discount]).to include(type: "percent", percents: 25)
        expect(result[:products_data][cross_sell_product1.unique_permalink][:discount]).to include(type: "percent", percents: 50)
        expect(result[:error_code]).to be_nil
      end

      it "skips cross-sell discounts when the buyer does not qualify" do
        create(
          :offer_code,
          user: seller,
          code: shared_code_name,
          products: [cross_sell_product1],
          ownership_products: [owned_product],
          existing_customers_only: true,
          amount_cents: nil,
          amount_percentage: 25,
          currency_type: nil
        )

        result = OfferCodeDiscountComputingService.new(shared_code_name, products_data, buyer:).process

        expect(result[:products_data]).to include(product.unique_permalink)
        expect(result[:products_data]).not_to include(cross_sell_product1.unique_permalink)
        expect(result[:error_code]).to be_nil
      end
    end
  end

  describe "existing-customer-only offer codes" do
    let(:owned_product) { product }
    let(:buyer) { create(:user) }
    let(:offer_code) do
      create(:offer_code,
             user: seller,
             products: [product],
             ownership_products: [owned_product],
             existing_customers_only: true,
             amount_cents: nil,
             amount_percentage: 25,
             currency_type: nil)
    end
    let(:products_data) do
      { product.unique_permalink => { quantity: "1", permalink: product.unique_permalink } }
    end

    it "rejects redemption with :not_existing_customer when the buyer has no qualifying purchase" do
      result = OfferCodeDiscountComputingService.new(offer_code.code, products_data, buyer:).process
      expect(result[:error_code]).to eq(:not_existing_customer)
    end

    it "rejects redemption with :not_existing_customer when buyer is nil" do
      result = OfferCodeDiscountComputingService.new(offer_code.code, products_data, buyer: nil).process
      expect(result[:error_code]).to eq(:not_existing_customer)
    end

    it "applies the discount when the buyer owns a required product" do
      create(:purchase, purchaser: buyer, link: owned_product, seller:, price_cents: owned_product.price_cents)
      result = OfferCodeDiscountComputingService.new(offer_code.code, products_data, buyer:).process
      expect(result[:error_code]).to be_nil
      expect(result[:products_data][product.unique_permalink][:discount]).to include(type: "percent", percents: 25)
    end

    it "resolves to the matching tier percentage when the code is tiered" do
      offer_code.update!(
        amount_percentage: 0,
        ownership_duration_tiers: [
          { "months" => 0, "amount_percentage" => 10 },
          { "months" => 6, "amount_percentage" => 30 },
        ],
      )
      create(:purchase, purchaser: buyer, link: owned_product, seller:, price_cents: owned_product.price_cents, created_at: 8.months.ago)

      result = OfferCodeDiscountComputingService.new(offer_code.code, products_data, buyer:).process

      expect(result[:error_code]).to be_nil
      expect(result[:products_data][product.unique_permalink][:discount]).to include(type: "percent", percents: 30)
    end
  end
end
