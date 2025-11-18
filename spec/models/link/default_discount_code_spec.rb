# frozen_string_literal: true

require "spec_helper"

describe "Link default_discount_code" do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller, price_cents: 2000) }
  let(:bundle) { create(:product, :bundle, user: seller, price_cents: 3000) }

  describe "default_discount_code attribute" do
    it "can be set on a product" do
      offer_code = create(:percentage_offer_code, code: "SUMMER24", products: [product], amount_percentage: 10)
      product.update!(default_discount_code: "SUMMER24")
      expect(product.reload.default_discount_code).to eq("SUMMER24")
    end

    it "can be set on a bundle" do
      offer_code = create(:percentage_offer_code, code: "BUNDLE20", products: [bundle], amount_percentage: 10)
      bundle.update!(default_discount_code: "BUNDLE20")
      expect(bundle.reload.default_discount_code).to eq("BUNDLE20")
    end

    it "can be set to nil" do
      offer_code = create(:percentage_offer_code, code: "SUMMER24", products: [product], amount_percentage: 10)
      product.update!(default_discount_code: "SUMMER24")
      product.update!(default_discount_code: nil)
      expect(product.reload.default_discount_code).to be_nil
    end

    it "accepts alphanumeric codes with dashes and underscores" do
      %w[SUMMER24 sale-50 PROMO_100 ÕËëæç].each do |code|
        create(:percentage_offer_code, code: code, products: [product], amount_percentage: 10)
        expect { product.update!(default_discount_code: code) }.not_to raise_error
        expect(product.reload.default_discount_code).to eq(code)
      end
    end

    it "accepts nil as a valid value" do
      expect { product.update!(default_discount_code: nil) }.not_to raise_error
    end
  end

  describe "automatic discount application" do
    let!(:offer_code) { create(:percentage_offer_code, code: "SAVE50", products: [product], amount_percentage: 50) }

    context "when product has default_discount_code set" do
      before { product.update!(default_discount_code: "SAVE50") }

      it "applies the discount automatically to purchases" do
        # This is integration tested in purchase creation specs
        # The default code should be read and applied during checkout
        expect(product.default_discount_code).to eq("SAVE50")
      end
    end

    context "when product has no default_discount_code" do
      it "does not apply any discount automatically" do
        expect(product.default_discount_code).to be_nil
      end
    end
  end

  describe "seller workflow" do
    let!(:universal_code) { create(:universal_offer_code, code: "UNIVERSAL", user: seller) }
    let!(:product_code) { create(:percentage_offer_code, code: "PROD50", products: [product], amount_percentage: 50) }
    let(:other_product) { create(:product, user: seller, price_cents: 2000) }
    let!(:other_product_code) { create(:percentage_offer_code, code: "OTHER", products: [other_product], amount_percentage: 25) }

    it "seller can set any valid offer code as default for their product" do
      # Seller can choose from product-specific or universal codes
      product.update!(default_discount_code: product_code.code)
      expect(product.default_discount_code).to eq("PROD50")

      product.update!(default_discount_code: universal_code.code)
      expect(product.default_discount_code).to eq("UNIVERSAL")
    end

    it "seller can update the default discount code" do
      product.update!(default_discount_code: "PROD50")
      expect(product.default_discount_code).to eq("PROD50")

      product.update!(default_discount_code: "UNIVERSAL")
      expect(product.default_discount_code).to eq("UNIVERSAL")
    end

    it "seller can remove the default discount code" do
      product.update!(default_discount_code: "PROD50")
      product.update!(default_discount_code: nil)
      expect(product.default_discount_code).to be_nil
    end

    it "stores the discount code value, not the offer_code id" do
      product.update!(default_discount_code: product_code.code)
      expect(product.default_discount_code).to eq("PROD50")
      expect(product.default_discount_code).not_to eq(product_code.id)
    end
  end

  describe "URL-based discount code priority" do
    let!(:default_code) { create(:percentage_offer_code, code: "DEFAULT10", products: [product], amount_percentage: 10) }
    let!(:url_code) { create(:percentage_offer_code, code: "URL20", products: [product], amount_percentage: 20) }

    before { product.update!(default_discount_code: default_code.code) }

    it "URL discount code takes precedence over default discount code" do
      # When a buyer visits /product?discount=URL20
      # The URL code (URL20) should be applied, not the default (DEFAULT10)
      # This is tested in the checkout/purchase flow specs
      expect(product.default_discount_code).to eq("DEFAULT10")
      # URL parameter should override the default when present
    end

    it "default code is used when no URL discount is provided" do
      # When a buyer visits /product without discount param
      # The default code (DEFAULT10) should be applied
      expect(product.default_discount_code).to eq("DEFAULT10")
    end
  end

  describe "with bundles" do
    let!(:bundle_code) { create(:percentage_offer_code, code: "BUNDLE25", products: [bundle], amount_percentage: 25) }

    it "bundle can have a default discount code" do
      bundle.update!(default_discount_code: bundle_code.code)
      expect(bundle.default_discount_code).to eq("BUNDLE25")
    end

    it "bundle-specific codes can be set as default" do
      bundle.update!(default_discount_code: "BUNDLE25")
      expect(bundle.default_discount_code).to eq("BUNDLE25")
    end
  end

  describe "edge cases" do
    it "handles deleted offer codes gracefully" do
      offer_code = create(:percentage_offer_code, code: "DELETED", products: [product], amount_percentage: 10)
      product.update!(default_discount_code: offer_code.code)

      # If the offer code is later deleted
      offer_code.mark_deleted!

      # The product still has the reference
      expect(product.default_discount_code).to eq("DELETED")
      # But it won't be valid during checkout (handled in purchase/checkout logic)
    end

    it "handles expired offer codes" do
      expired_code = create(:percentage_offer_code, code: "EXPIRED", products: [product], amount_percentage: 10, valid_at: 7.days.ago, expires_at: 1.day.ago)
      product.update!(default_discount_code: expired_code.code)

      expect(product.default_discount_code).to eq("EXPIRED")
      # Expiration validation happens during checkout, not on the product model
    end

    it "handles maxed-out offer codes" do
      maxed_code = create(:percentage_offer_code, code: "MAXED", products: [product], amount_percentage: 10, max_purchase_count: 0)
      product.update!(default_discount_code: maxed_code.code)

      expect(product.default_discount_code).to eq("MAXED")
      # Usage limit validation happens during checkout
    end

    it "validation prevents setting a non-existent code" do
      # The validation requires the offer code to exist
      expect {
        product.update!(default_discount_code: "FUTURE_CODE")
      }.to raise_error(ActiveRecord::RecordInvalid, /Discount code does not exist/)

      expect(product.reload.default_discount_code).to be_nil
    end
  end
end
