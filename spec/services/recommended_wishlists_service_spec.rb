# frozen_string_literal: true

require "spec_helper"

describe RecommendedWishlistsService do
  describe ".fetch" do
    let!(:wishlists) do
      5.times.map { |i| create(:wishlist, name: "Recommendable #{i}", recent_follower_count: i, recommendable: true) }
    end

    let(:recommended_products) { create_list(:product, 4) }
    let(:taxonomy) { Taxonomy.last }

    before do
      wishlists.each { create(:wishlist_product, wishlist: _1) }
    end

    it "returns wishlists ordered by recent_follower_count when no additional params are provided" do
      result = described_class.fetch(limit: 4, current_seller: nil)
      expect(result.count).to eq(4)
      expect(result).to eq(wishlists.last(4).reverse)
    end

    it "excludes wishlists owned by the current seller" do
      result = described_class.fetch(limit: 4, current_seller: wishlists.last.user)
      expect(result).to eq(wishlists.first(4).reverse)
    end

    it "prioritizes wishlists with recommended products" do
      wishlists.first(4).each.with_index do |wishlist, i|
        create(:wishlist_product, wishlist: wishlist, product: recommended_products[i])
      end

      result = described_class.fetch(limit: 4, current_seller: nil, curated_product_ids: recommended_products.pluck(:id))
      expect(result).to eq(wishlists.first(4).reverse)
    end

    it "returns nothing if there are no product matches" do
      result = described_class.fetch(limit: 4, current_seller: nil, curated_product_ids: [create(:product).id])
      expect(result).to be_empty
    end

    it "fills remaining slots with non-matching wishlists if not enough matches" do
      create(:wishlist_product, wishlist: wishlists.first, product: recommended_products.second)

      result = described_class.fetch(limit: 4, current_seller: nil, curated_product_ids: recommended_products.pluck(:id))
      expect(result).to eq([wishlists.first, *wishlists.last(3).reverse])
    end

    it "filters wishlists by taxonomy_id" do
      taxonomy_product = create(:product, taxonomy: taxonomy)
      taxonomy_wishlist = create(:wishlist, name: "Taxonomy wishlist", recommendable: true)
      create(:wishlist_product, wishlist: taxonomy_wishlist, product: taxonomy_product)

      result = described_class.fetch(limit: 4, current_seller: nil, taxonomy_id: taxonomy.id)
      expect(result).to eq([taxonomy_wishlist])
    end

    it "returns nothing if there are no taxonomy matches" do
      result = described_class.fetch(limit: 4, current_seller: nil, taxonomy_id: create(:taxonomy).id)
      expect(result).to be_empty
    end
  end
end
