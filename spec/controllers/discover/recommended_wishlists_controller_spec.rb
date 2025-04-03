# frozen_string_literal: true

require "spec_helper"

describe Discover::RecommendedWishlistsController do
  describe "GET #index" do
    let(:user) { create(:user) }
    let(:wishlists) { Wishlist.where(id: create_list(:wishlist, 4).map(&:id)) }
    let(:taxonomy) { Taxonomy.last }

    before do
      sign_in user
    end

    it "fetches user recommendations" do
      expect(RecommendedWishlistsService).to receive(:fetch).with(
        limit: 4,
        current_seller: user,
        curated_product_ids: [1, 2, 3],
        taxonomy_id: nil
      ).and_return(wishlists)

      get :index, params: { curated_product_ids: [ObfuscateIds.encrypt(1), ObfuscateIds.encrypt(2), ObfuscateIds.encrypt(3)], taxonomy: "" }

      expect(response).to be_successful
      expect(response.parsed_body).to eq WishlistPresenter.cards_props(
        wishlists:,
        pundit_user: SellerContext.new(user:, seller: user),
        layout: Product::Layout::DISCOVER,
        recommended_by: RecommendationType::GUMROAD_DISCOVER_WISHLIST_RECOMMENDATION,
      ).as_json
    end

    it "fetches category recommendations" do
      expect(RecommendedWishlistsService).to receive(:fetch).with(
        limit: 4,
        current_seller: user,
        curated_product_ids: [],
        taxonomy_id: taxonomy.id
      ).and_return(wishlists)

      get :index, params: { taxonomy: taxonomy.self_and_ancestors.map(&:slug).join("/") }

      expect(response).to be_successful
    end
  end
end
