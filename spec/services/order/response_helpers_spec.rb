# frozen_string_literal: true

describe Order::ResponseHelpers do
  let(:seller) { create(:user) }
  let(:usd_product) { create(:product, user: seller, price_cents: 15_00, price_currency_type: Currency::USD) }
  let(:eur_product) { create(:product, user: seller, price_cents: 15_00, price_currency_type: Currency::EUR) }
  let(:gbp_product) { create(:product, user: seller, price_cents: 15_00, price_currency_type: Currency::GBP) }

  let(:test_class) do
    Class.new do
      include Order::ResponseHelpers
    end
  end
  let(:test_instance) { test_class.new }

  describe "#error_response" do
    it "returns error response for failed purchase" do
      purchase = create(:failed_purchase, link: usd_product, total_transaction_cents: 15_00, error_code: "insufficient_funds")

      response = test_instance.send(:error_response, "Payment declined", purchase:)

      expect(response).to include(
        success: false,
        error_message: "Payment declined",
        permalink: usd_product.unique_permalink,
        name: usd_product.name,
        formatted_price: "$15",
        error_code: "insufficient_funds",
        is_tax_mismatch: false,
        ip_country: purchase.ip_country,
      )
    end

    it "returns formatted price using USD total transaction cents" do
      purchase = create(:failed_purchase, link: eur_product, total_transaction_cents: 25_00, error_code: "generic_decline")

      response = test_instance.send(:error_response, "Payment declined", purchase:)

      expect(response[:formatted_price]).to eq("$25")
    end

    it "sets is_tax_mismatch to true when error_code is TAX_VALIDATION_FAILED" do
      purchase = create(:failed_purchase, link: usd_product, total_transaction_cents: 10_00, error_code: PurchaseErrorCode::TAX_VALIDATION_FAILED)

      response = test_instance.send(:error_response, "Tax validation failed", purchase:)

      expect(response[:is_tax_mismatch]).to eq(true)
      expect(response[:error_code]).to eq(PurchaseErrorCode::TAX_VALIDATION_FAILED)
    end

    it "handles CN card country code correctly" do
      purchase = create(:failed_purchase, link: usd_product, total_transaction_cents: 10_00, card_country: "C2")

      response = test_instance.send(:error_response, "Payment failed", purchase:)

      expect(response[:card_country]).to eq("China")
    end

    it "handles nil purchase gracefully" do
      response = test_instance.send(:error_response, "Generic error", purchase: nil)

      expect(response).to include(
        success: false,
        error_message: "Generic error",
        name: nil,
        formatted_price: "$0",
        error_code: nil,
        is_tax_mismatch: false
      )
    end
  end
end
