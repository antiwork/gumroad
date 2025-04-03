# frozen_string_literal: true

require "spec_helper"
require "shared_examples/max_purchase_count_concern"

describe Sku do
  it_behaves_like "MaxPurchaseCount concern", :sku

  describe "sku_category_name" do
    before do
      link = create(:product)
      @variant_category_1 = create(:variant_category, link:, title: "Size")
      @variant_category_2 = create(:variant_category, link:, title: "Color")
      @sku = create(:sku, link:)
    end

    it "has the proper category name given 2 variants" do
      expect(@sku.sku_category_name).to eq "Size - Color"
    end

    it "has the proper category name given 1 variants" do
      @variant_category_2.update_attribute(:deleted_at, Time.current)
      expect(@sku.sku_category_name).to eq "Size"
    end
  end

  describe "as_json" do
    before do
      link = create(:product)
      @variant_category_1 = create(:variant_category, link:, title: "Size")
      @variant_category_2 = create(:variant_category, link:, title: "Color")
      @sku = create(:sku, link:, custom_sku: "customSKU")
    end

    it "includes custom_sku" do
      json = @sku.as_json(for_views: true)
      expect(json["custom_sku"]).to eq("customSKU")
    end

    it "does not include custom_sku if it does not exist" do
      @sku.update_attribute(:custom_sku, nil)
      json = @sku.as_json(for_views: true)
      expect(json["custom_sku"]).to be_nil
    end
  end

  describe "#to_option" do
    it "returns a hash of attributes for use in checkout" do
      sku = create(:sku, name: "Red")

      expect(sku.to_option).to eq(
        id: sku.external_id,
        name: sku.name,
        quantity_left: nil,
        description: "",
        price_difference_cents: 0,
        recurrence_price_values: nil,
        is_pwyw: false,
        duration_in_minutes: nil,
      )
    end
  end

  describe "#to_option_for_product" do
    it "returns a hash of attributes" do
      sku = create(:sku, name: "Red")

      expect(sku.to_option_for_product).to eq(
        id: sku.external_id,
        name: sku.name,
        quantity_left: nil,
        description: "",
        price_difference_cents: 0,
        recurrence_price_values: nil,
        is_pwyw: false,
        duration_in_minutes: nil,
      )
    end
  end

  describe "updating price_difference_cents" do
    let(:product) { create(:product) }
    let!(:sku) { create(:sku, link: product, custom_sku: "customSKU", price_difference_cents: 20) }

    it "enqueues Elasticsearch update if a price_difference_cents has changed" do
      expect(product).to receive(:enqueue_index_update_for).with(["available_price_cents"])
      sku.update!(price_difference_cents: 10)
    end

    it "does not enqueue Elasticsearch update if prices have not changed" do
      expect(product).not_to receive(:enqueue_index_update_for).with(["available_price_cents"])
      sku.update!(price_difference_cents: 20)
    end
  end
end
