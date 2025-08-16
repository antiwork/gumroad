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
      let(:specific_offer_code) { create(:offer_code, user: seller, products: [product, cross_sell_product1], amount_percentage: 25, amount_cents: nil, currency_type: "usd") }

      it "applies discount only to applicable products including cross-sells" do
        result = OfferCodeDiscountComputingService.new(specific_offer_code.code, products_data).process

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
              percents: 25
            )
          }
        )
        expect(result[:products_data]).not_to include(cross_sell_product2.unique_permalink)
        expect(result[:products_data]).not_to include(additive_cross_sell_product.unique_permalink)
        expect(result[:error_code]).to be_nil
      end
    end
  end
end
