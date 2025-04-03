# frozen_string_literal: true

require "spec_helper"

describe OfferCodeDiscountComputingService do
  let(:product) { create(:product, user: create(:user), price_cents: 2000, price_currency_type: "usd") }
  let(:product2) { create(:product, user: product.user, price_cents: 2000, price_currency_type: "usd") }
  let(:universal_offer_code) { create(:universal_offer_code, user: product.user, amount_percentage: 100, amount_cents: nil, currency_type: product.price_currency_type) }
  let(:offer_code) { create(:offer_code, products: [product], amount_percentage: 100, amount_cents: nil, currency_type: product.price_currency_type) }
  let(:zero_percent_discount_code) { create(:offer_code, products: [product], amount_percentage: 0, amount_cents: nil, currency_type: product.price_currency_type) }
  let(:zero_cents_discount_code) { create(:offer_code, products: [product], amount_percentage: nil, amount_cents: 0, currency_type: product.price_currency_type) }
  let(:products_data) do
    {
      product.id => { quantity: "3", permalink: product.unique_permalink },
      product2.id => { quantity: "2", permalink: product2.unique_permalink }
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
      product.id => {
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
      product2.id => {
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
      product2.id => {
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
      product.id => {
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
      product.id => {
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
      product.id => {
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
      product.id => {
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
    expect(result[:error_code]).to eq(:exceeding_quantity)
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

      expect(result[:error_code]).to eq(:insufficient_quantity)
      expect(result[:products_data]).to eq({})
    end
  end
end
