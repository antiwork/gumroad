# frozen_string_literal: true

require "spec_helper"

describe Product::Utils do
  describe ".f" do
    it "fetches product from unique permalink" do
      product = create(:product)

      expect(Link.f(product.unique_permalink)).to eq(product)
    end

    it "fetches product from custom permalink" do
      product = create(:product, custom_permalink: "FindMeAHex")

      expect(Link.f("FindMeAHex")).to eq(product)
    end

    context "when multiple products with the same custom permalink" do
      before do
        @product_1 = create(:product, custom_permalink: "custom")
        @product_2 = create(:product, custom_permalink: "custom")
      end

      it "raises an error when custom permalink matches more than one product" do
        expect { Link.f("custom") }.to raise_error(ActiveRecord::RecordNotUnique)
      end

      it "fetches the correct product when scoped to a given user" do
        expect(Link.f("custom", @product_2.user_id)).to eq(@product_2)
      end
    end

    it "fetches product from id" do
      product = create(:product)

      expect(Link.f(product.id)).to eq(product)
    end

    it "raises error if no product found" do
      expect { Link.f(42) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
