# frozen_string_literal: true

require "spec_helper"

describe SaveUpsellService do
  let(:seller) { create(:user) }
  let(:product) { create(:product_with_digital_versions, user: seller, price_cents: 1000) }
  let(:other_product) { create(:product_with_digital_versions, user: seller, price_cents: 500) }

  def params(overrides = {})
    ActionController::Parameters.new(overrides)
  end

  describe "creating an upsell" do
    it "builds a version-change upsell with its upsell variants" do
      upsell = described_class.new(
        seller:,
        params: params(
          name: "Upgrade",
          text: "Upgrade now",
          description: "Better tier",
          cross_sell: false,
          product_id: product.external_id,
          upsell_variants: [{ selected_variant_id: product.alive_variants.first.external_id, offered_variant_id: product.alive_variants.second.external_id }],
        )
      ).perform

      expect(upsell.save).to be(true)
      expect(upsell.name).to eq("Upgrade")
      expect(upsell.cross_sell).to be(false)
      expect(upsell.product).to eq(product)
      expect(upsell.variant).to be_nil
      expect(upsell.upsell_variants.length).to eq(1)
      expect(upsell.upsell_variants.first.selected_variant).to eq(product.alive_variants.first)
      expect(upsell.upsell_variants.first.offered_variant).to eq(product.alive_variants.second)
    end

    it "builds a cross-sell with a discounted offer code and selected products" do
      upsell = described_class.new(
        seller:,
        params: params(
          name: "Cross-sell",
          cross_sell: true,
          replace_selected_products: true,
          product_id: product.external_id,
          variant_id: product.alive_variants.first.external_id,
          product_ids: [other_product.external_id],
          offer_code: { amount_cents: 200 },
        )
      ).perform

      expect(upsell.save).to be(true)
      expect(upsell.cross_sell).to be(true)
      expect(upsell.replace_selected_products).to be(true)
      expect(upsell.variant).to eq(product.alive_variants.first)
      expect(upsell.selected_products).to eq([other_product])
      expect(upsell.offer_code.amount_cents).to eq(200)
      expect(upsell.offer_code.products).to eq([product])
    end

    it "does not persist an upsell with a variant from another product" do
      foreign_variant = create(:product_with_digital_versions).alive_variants.first
      upsell = described_class.new(
        seller:,
        params: params(
          name: "Invalid",
          cross_sell: true,
          product_id: product.external_id,
          variant_id: foreign_variant.external_id,
          product_ids: [other_product.external_id],
        )
      ).perform

      expect(upsell.save).to be(false)
      expect(upsell.errors.full_messages).to include("The offered variant must belong to the offered product.")
    end
  end

  describe "updating an upsell" do
    let!(:upsell) { create(:upsell, seller:, product:, name: "Original", cross_sell: true) }

    it "updates the offer code and replaces it with a percentage discount" do
      described_class.new(seller:, params: params(product_id: product.external_id, offer_code: { amount_cents: 200 }), upsell:).perform
      expect(upsell.save).to be(true)
      expect(upsell.reload.offer_code.amount_cents).to eq(200)

      described_class.new(seller:, params: params(product_id: product.external_id, offer_code: { amount_percentage: 10 }), upsell:).perform
      expect(upsell.save).to be(true)
      expect(upsell.reload.offer_code.amount_cents).to be_nil
      expect(upsell.offer_code.amount_percentage).to eq(10)
    end

    it "removes the offer code when none is provided" do
      upsell.update!(offer_code: create(:offer_code, products: [product], user: seller))

      described_class.new(seller:, params: params(product_id: product.external_id), upsell:).perform
      expect(upsell.save).to be(true)
      expect(upsell.reload.offer_code).to be_nil
    end

    it "keeps scalar attributes that are not in the params" do
      described_class.new(seller:, params: params(product_id: product.external_id, name: "Renamed"), upsell:).perform
      expect(upsell.save).to be(true)
      expect(upsell.reload.name).to eq("Renamed")
      expect(upsell.text).to eq("Take advantage of this excellent offer!")
    end

    it "re-activates a variant mapping that was previously removed" do
      versioned = create(:upsell, seller:, product:, name: "Versioned", cross_sell: false)
      first = product.alive_variants.first
      second = product.alive_variants.second
      create(:upsell_variant, upsell: versioned, selected_variant: first, offered_variant: second)

      described_class.new(seller:, params: params(product_id: product.external_id, upsell_variants: [{ selected_variant_id: second.external_id, offered_variant_id: first.external_id }]), upsell: versioned).perform
      expect(versioned.save).to be(true)
      expect(versioned.reload.upsell_variants.alive.map(&:selected_variant)).to eq([second])

      described_class.new(seller:, params: params(product_id: product.external_id, upsell_variants: [{ selected_variant_id: first.external_id, offered_variant_id: second.external_id }]), upsell: versioned).perform
      expect(versioned.save).to be(true)
      expect(versioned.reload.upsell_variants.alive.map(&:selected_variant)).to eq([first])
      expect(versioned.upsell_variants.alive.first.offered_variant).to eq(second)
    end
  end
end
