# frozen_string_literal: true

require "spec_helper"

describe Purchase::CreateService, "default discount tracking" do
  let(:user) { create(:user) }
  let(:product) { create(:product, user: user, price_cents: 10_00) }
  let(:offer_code) { create(:offer_code, user: user, products: [product], amount_cents: 2_00) }

  describe "when a URL discount code is provided" do
    before do
      product.update!(default_offer_code: offer_code, default_offer_code_enabled: true)
    end

    let(:url_offer_code) { create(:offer_code, user: user, products: [product], amount_cents: 1_00, code: "URL50") }

    it "uses the URL code and sets discount_source to 'url'" do
      service = Purchase::CreateService.new(
        product,
        { discount_code: "URL50", email: "test@example.com" }
      )

      purchase = service.purchase
      expect(purchase.offer_code).to eq(url_offer_code)
      expect(purchase.discount_source).to eq("url")
      expect(purchase.used_default_discount).to be false
    end
  end

  describe "when no URL discount code is provided and default is enabled" do
    before do
      product.update!(default_offer_code: offer_code, default_offer_code_enabled: true)
    end

    it "uses the default offer code and sets tracking fields" do
      service = Purchase::CreateService.new(
        product,
        { email: "test@example.com" }
      )

      purchase = service.purchase
      expect(purchase.offer_code).to eq(offer_code)
      expect(purchase.discount_source).to eq("default")
      expect(purchase.used_default_discount).to be true
    end
  end

  describe "when no URL discount code is provided and default is disabled" do
    before do
      product.update!(default_offer_code: offer_code, default_offer_code_enabled: false)
    end

    it "does not apply any discount" do
      service = Purchase::CreateService.new(
        product,
        { email: "test@example.com" }
      )

      purchase = service.purchase
      expect(purchase.offer_code).to be_nil
      expect(purchase.discount_source).to be_nil
      expect(purchase.used_default_discount).to be false
    end
  end

  describe "when default offer code has expired" do
    before do
      offer_code.update_column(:expires_at, 1.day.ago)
      product.update!(default_offer_code: offer_code, default_offer_code_enabled: true)
    end

    it "does not apply the default discount" do
      service = Purchase::CreateService.new(
        product,
        { email: "test@example.com" }
      )

      purchase = service.purchase
      expect(purchase.offer_code).to be_nil
      expect(purchase.discount_source).to be_nil
      expect(purchase.used_default_discount).to be false
    end
  end
end
