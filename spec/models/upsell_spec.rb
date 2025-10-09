# frozen_string_literal: true

require "spec_helper"

describe Upsell do
  describe "validations" do
    context "when any products don't belong to the seller" do
      before do
        @upsell = build(:upsell, selected_products: [create(:product)])
      end

      it "adds an error" do
        expect(@upsell.valid?).to eq(false)
        expect(@upsell.errors.full_messages.first).to eq("All offered products must belong to the current seller.")
      end
    end

    context "when all products belong to the seller" do
      before do
        @seller = create(:user)
        @upsell = build(:upsell, selected_products: [create(:product, user: @seller)], seller: @seller)
      end

      it "doesn't add an error" do
        expect(@upsell.valid?).to eq(true)
      end
    end

    context "when the offered product doesn't belong to the seller" do
      before do
        @upsell = build(:upsell, product: create(:product))
      end

      it "adds an error" do
        expect(@upsell.valid?).to eq(false)
        expect(@upsell.errors.full_messages.first).to eq("The offered product must belong to the current seller.")
      end
    end

    context "when the offered product belongs to the seller" do
      before do
        @seller = create(:user)
        @upsell = build(:upsell, product: create(:product, user: @seller), seller: @seller)
      end

      it "doesn't add an error" do
        expect(@upsell.valid?).to eq(true)
      end
    end

    context "when the offered product is a call" do
      before do
        @seller = create(:user, :eligible_for_service_products)
        @upsell = build(:upsell, product: create(:call_product, user: @seller), seller: @seller)
      end

      it "adds an error" do
        expect(@upsell.valid?).to eq(false)
        expect(@upsell.errors.full_messages.first).to eq("Calls cannot be offered as upsells.")
      end
    end

    context "when the offered variant doesn't belong to the the offered product" do
      before do
        @upsell = build(:upsell, variant: create(:variant))
      end

      it "adds an error" do
        expect(@upsell.valid?).to eq(false)
        expect(@upsell.errors.full_messages.first).to eq("The offered variant must belong to the offered product.")
      end
    end

    context "when the offered variant belongs to the offered product" do
      before do
        @seller = create(:user)
        @product = create(:product, user: @seller)
        @upsell = build(:upsell, product: @product, variant: create(:variant, variant_category: create(:variant_category, link: @product)), seller: @seller)
      end

      it "doesn't add an error" do
        expect(@upsell.valid?).to eq(true)
      end
    end

    context "when the offer code doesn't belong to the seller and the offered product" do
      before do
        @upsell = build(:upsell, offer_code: create(:offer_code))
      end

      it "adds an error" do
        expect(@upsell.valid?).to eq(false)
        expect(@upsell.errors.full_messages.first).to eq("The offer code must belong to the seller and the offered product.")
      end
    end

    context "when the offer code belongs to the seller and the offered product" do
      before do
        @seller = create(:user)
        @product = create(:product, user: @seller)
        @upsell = build(:upsell, product: @product, offer_code: create(:offer_code, user: @seller, products: [@product]), seller: @seller)
      end

      it "doesn't add an error" do
        expect(@upsell.valid?).to eq(true)
      end
    end

    context "when there is more than one upsell variant per selected variant" do
      before do
        @seller = create(:user)
        @product = create(:product, user: @seller)
        @selected_variant = create(:variant, variant_category: create(:variant_category, link: @product))
        @upsell = build(:upsell, seller: @seller, product: @product)
        create_list(:upsell_variant, 2, upsell: @upsell, selected_variant: @selected_variant)
      end

      it "adds an error" do
        expect(@upsell.valid?).to eq(false)
        expect(@upsell.errors.full_messages.first).to eq("The upsell cannot have more than one upsell variant per selected variant.")
      end
    end

    context "when there is only one upsell variant per selected variant" do
      before do
        @seller = create(:user)
        @upsell = build(:upsell, seller: @seller)
        create_list(:upsell_variant, 2, upsell: @upsell)
      end

      it "doesn't add an error" do
        expect(@upsell.valid?).to eq(true)
      end
    end

    context "when there is already an upsell for the product" do
      before do
        @seller = create(:user)
        @product = create(:product, user: @seller)
        @existing_upsell = create(:upsell, seller: @seller, product: @product)
        @upsell = build(:upsell, seller: @seller, product: @product)
      end

      it "adds an error" do
        expect(@upsell.valid?).to eq(false)
        expect(@upsell.errors.full_messages.first).to eq("You can only create one upsell per product.")
      end

      context "when `deleted_at` is set for the upsell" do
        before do
          @upsell.deleted_at = Time.current
        end

        it "doesn't add an error" do
          expect(@upsell.valid?).to eq(true)
        end
      end
    end

    context "when there isn't an upsell for the product" do
      before do
        @seller = create(:user)
        @product = create(:product, user: @seller)
        @existing_cross_sell = create(:upsell, cross_sell: true, seller: @seller, product: @product)
        @upsell = build(:upsell, seller: @seller, product: @product)
      end

      it "doesn't add an error" do
        expect(@upsell.valid?).to eq(true)
      end
    end
  end

  describe "#as_json" do
    let(:seller) { create(:named_seller) }
    let(:product1) { create(:product_with_digital_versions, user: seller, price_cents: 1000) }
    let(:product2) { create(:product_with_digital_versions, user: seller, price_cents: 500) }
    let!(:upsell1) { create(:upsell, product: product1, variant: product1.alive_variants.second, name: "Upsell 1", seller:, cross_sell: true, replace_selected_products: true) }
    let!(:upsell2) { create(:upsell, product: product2, offer_code: create(:offer_code, products: [product2], user: seller), name: "Upsell 2", seller:) }
    let!(:upsell2_variant) { create(:upsell_variant, upsell: upsell2, selected_variant: product2.alive_variants.first, offered_variant: product2.alive_variants.second) }

    before do
      build_list :product, 5 do |product, i|
        product.name = "Product #{i}"
        create_list(:upsell_purchase, 2, upsell: upsell1, selected_product: product)
        upsell1.selected_products << product
      end

      create_list(:upsell_purchase, 20, upsell: upsell2, selected_product: product2, upsell_variant: upsell2_variant)
    end

    it "returns the upsell encoded in an object" do
      expect(upsell1.as_json).to eq(
        {
          description: "This offer will only last for a few weeks.",
          id: upsell1.external_id,
          name: "Upsell 1",
          text: "Take advantage of this excellent offer!",
          cross_sell: true,
          replace_selected_products: true,
          universal: false,
          paused: false,
          discount: nil,
          product: {
            id: product1.external_id,
            currency_type: "usd",
            name: "The Works of Edgar Gumstein",
            variant: {
              id: product1.alive_variants.second.external_id,
              name: "Untitled 2"
            },
          },
          selected_products: [
            { id: upsell1.selected_products[0].external_id, name: "Product 0" },
            { id: upsell1.selected_products[1].external_id, name: "Product 1" },
            { id: upsell1.selected_products[2].external_id, name: "Product 2" },
            { id: upsell1.selected_products[3].external_id, name: "Product 3" },
            { id: upsell1.selected_products[4].external_id, name: "Product 4" },
          ],
          upsell_variants: [],
        })

      expect(upsell2.as_json).to eq(
        {
          description: "This offer will only last for a few weeks.",
          id: upsell2.external_id,
          name: "Upsell 2",
          text: "Take advantage of this excellent offer!",
          cross_sell: false,
          replace_selected_products: false,
          universal: false,
          paused: false,
          discount: {
            cents: 100,
            type: "fixed",
            product_ids: [product2.external_id],
            expires_at: nil,
            minimum_quantity: nil,
            duration_in_billing_cycles: nil,
            minimum_amount_cents: nil,
          },
          product: {
            id: product2.external_id,
            currency_type: "usd",
            name: "The Works of Edgar Gumstein",
            variant: nil,
          },
          selected_products: [],
          upsell_variants: [{
            id: upsell2_variant.external_id,
            selected_variant: {
              id: upsell2_variant.selected_variant.external_id,
              name: upsell2_variant.selected_variant.name,
            },
            offered_variant: {
              id: upsell2_variant.offered_variant.external_id,
              name: upsell2_variant.offered_variant.name,
            },
          }],
        }
      )
    end
  end
end
