# frozen_string_literal: true

require "spec_helper"

describe RecommendedProductsController do
  describe "GET index" do
    let(:recommender_model_name) { RecommendedProductsService::MODEL_SALES }
    let(:cart_product) { create(:product) }
    let(:products) { create_list(:product, 5) }
    let(:products_relation) { Link.where(id: products.map(&:id)) }
    let(:product_cards) do
      products[0..2].map do |product|
        ProductPresenter.card_for_web(
          product:,
          request:,
          recommended_by:,
          recommender_model_name:,
          target:,
        )
      end
    end

    before do
      products.last.update!(deleted_at: Time.current)
      products.second_to_last.update!(archived: true)
    end

    let(:recommended_by) { RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION }
    let(:target) { Product::Layout::PROFILE }

    let(:purchaser) { create(:user) }
    let!(:purchase) { create(:purchase, purchaser:) }

    before do
      products.first.update!(user: purchase.link.user)
      cart_product.update!(user: purchase.link.user)
      index_model_records(Link)
      sign_in purchaser
    end

    it "calls CheckoutService and returns product cards" do
      expect(RecommendedProducts::CheckoutService).to receive(:fetch_for_cart).with(
        purchaser:,
        cart_product_ids: [cart_product.id],
        recommender_model_name:,
        limit: 5,
        recommendation_type: nil,
      ).and_call_original
      expect(RecommendedProductsService).to receive(:fetch).with(
        {
          model: RecommendedProductsService::MODEL_SALES,
          ids: [cart_product.id, purchase.link.id],
          exclude_ids: [cart_product.id, purchase.link.id],
          number_of_results: RecommendedProducts::BaseService::NUMBER_OF_RESULTS,
          user_ids: [cart_product.user.id],
        }
      ).and_return(Link.where(id: products.first.id))
      get(
        :index,
        params: { cart_product_ids: [cart_product.external_id], on_discover_page: "false", limit: "5" },
        session: { recommender_model_name: }
      )
      expect(response.parsed_body).to eq([product_cards.first.with_indifferent_access])
    end
  end
end
