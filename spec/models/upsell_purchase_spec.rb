# frozen_string_literal: true

require "spec_helper"

describe UpsellPurchase do
  describe "validations" do
    context "when the upsell doesn't belong to the purchase's product" do
      let(:upsell_purchase) { build(:upsell_purchase, selected_product: create(:product), purchase: create(:purchase, link: create(:product))) }

      it "adds an error" do
        expect(upsell_purchase.valid?).to eq(false)
        expect(upsell_purchase.errors.full_messages.first).to eq("The upsell must belong to the product being purchased.")
      end
    end

    context "when the upsell belongs to the purchase's product" do
      let(:upsell_purchase) { build(:upsell_purchase) }
      it "doesn't add an error" do
        expect(upsell_purchase.valid?).to eq(true)
      end
    end

    context "when the upsell purchase doesn't have an upsell variant for its upsell" do
      let(:upsell_purchase) { build(:upsell_purchase, upsell: create(:upsell)) }
      it "adds an error" do
        expect(upsell_purchase.valid?).to eq(false)
        expect(upsell_purchase.errors.full_messages.first).to eq("The upsell purchase must have an associated upsell variant.")
      end
    end

    context "when the upsell purchase has an upsell variant for its upsell" do
      let(:seller) { build(:named_seller) }
      let(:product) { build(:product_with_digital_versions, user: seller) }
      let(:upsell) { build(:upsell, seller:, product:) }
      let(:upsell_variant) { build(:upsell_variant, upsell:, selected_variant: product.alive_variants.first, offered_variant: product.alive_variants.second) }
      let(:upsell_purchase) { build(:upsell_purchase, upsell:, upsell_variant:, selected_product: product) }

      it "doesn't add an error" do
        expect(upsell_purchase.valid?).to eq(true)
      end
    end
  end

  describe "#as_json" do
    let(:seller) { create(:named_seller) }
    let(:product1) { create(:product_with_digital_versions, name: "Product 1", user: seller, price_cents: 1000) }
    let(:product2) { create(:product_with_digital_versions, name: "Product 2", user: seller, price_cents: 500) }

    context "for an upsell" do
      let(:upsell) { create(:upsell, product: product2, name: "Upsell 2", seller:) }
      let(:upsell_variant) { create(:upsell_variant, upsell:, selected_variant: product2.alive_variants.first, offered_variant: product2.alive_variants.second) }
      let(:upsell_purchase) { create(:upsell_purchase, upsell:, upsell_variant:, selected_product: product2) }

      it "returns the upsell purchase encoded in an object" do
        expect(upsell_purchase.as_json).to eq(
          {
            name: "Upsell 2",
            discount: nil,
            selected_product: product2.name,
            selected_version: product2.alive_variants.first.name,
          }
        )
      end
    end

    context "for a cross-sell" do
      let(:cross_sell) { create(:upsell, selected_products: [product2], product: product1, variant: product1.alive_variants.second, name: "Upsell 1", seller:, offer_code: create(:offer_code, products: [product1], user: seller), cross_sell: true) }
      let(:upsell_purchase) { create(:upsell_purchase, upsell: cross_sell, selected_product: product2) }

      before do
        upsell_purchase.purchase.create_purchase_offer_code_discount!(offer_code: cross_sell.offer_code, offer_code_amount: 100, pre_discount_minimum_price_cents: 100)
        cross_sell.offer_code.update!(amount_cents: 200)
      end

      it "returns the upsell purchase encoded in an object" do
        expect(upsell_purchase.as_json).to eq(
          {
            name: "Upsell 1",
            discount: "$1",
            selected_product: product2.name,
            selected_version: nil,
          }
        )
      end

      context "when the upsell is a content upsell" do
        let(:seller) { create(:named_seller) }
        let(:purchase) { create(:purchase, link: product1) }
        let(:content_upsell) do
          create(
            :upsell,
            name: "Content Upsell",
            product: product1,
            seller: seller,
            is_content_upsell: true,
            cross_sell: true
          )
        end
        let(:upsell_purchase) do
          create(
            :upsell_purchase,
            upsell: content_upsell,
            purchase: purchase,
            selected_product: nil
          )
        end

        it "returns nil for selected_product" do
          expect(upsell_purchase.as_json).to match(
            name: "Content Upsell",
            discount: "$1",
            selected_product: nil,
            selected_version: nil,
          )
        end
      end
    end
  end
end
