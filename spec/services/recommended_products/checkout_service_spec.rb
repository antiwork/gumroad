# frozen_string_literal: true

require "spec_helper"

describe RecommendedProducts::CheckoutService do
  let(:recommender_model_name) { RecommendedProductsService::MODEL_SALES }
  let(:products) { create_list(:product, 5) }

  let(:seller1) { create(:user) }
  let(:product1) { create(:product, user: seller1) }
  let(:seller2) { create(:user) }
  let(:product2) { create(:product, user: seller2) }
  let(:seller_with_no_recommendations) { create(:user, recommendation_type: User::RecommendationType::NO_RECOMMENDATIONS) }
  let(:product3) { create(:product, user: seller_with_no_recommendations) }

  let(:purchaser) { create(:user) }
  let!(:purchase) { create(:purchase, purchaser:, link: product2) }

  before do
    products.first.update!(user: seller1)
    index_model_records(Link)
  end

  describe ".fetch_for_cart" do
    it "initializes with the correct arguments" do
      expect(RecommendedProducts::CheckoutService).to receive(:new).with(
        purchaser:,
        cart_product_ids: [product1.id, product3.id],
        recommender_model_name:,
        recommended_by: RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION,
        target: Product::Layout::PROFILE,
        limit: 5,
        recommendation_type: nil,
      ).and_call_original
      described_class.fetch_for_cart(
        purchaser:,
        cart_product_ids: [product1.id, product3.id],
        recommender_model_name:,
        limit: 5
      )
    end
  end

  describe ".fetch_for_receipt" do
    it "initializes with the correct arguments" do
      expect(RecommendedProducts::CheckoutService).to receive(:new).with(
        purchaser:,
        cart_product_ids: [purchase.link.id],
        recommender_model_name:,
        recommended_by: RecommendationType::GUMROAD_RECEIPT_RECOMMENDATION,
        target: Product::Layout::PROFILE,
        limit: 5
      ).and_call_original
      described_class.fetch_for_receipt(
        purchaser:,
        receipt_product_ids: [purchase.link.id],
        recommender_model_name:,
        limit: 5
      )
    end
  end

  describe "#result" do
    it "passes user IDs for seller with recommendations turned on whose products are in the cart" do
      expect(RecommendedProductsService).to receive(:fetch).with(
        model: RecommendedProductsService::MODEL_SALES,
        ids: [product1.id, product3.id, product2.id],
        exclude_ids: [product1.id, product3.id, product2.id],
        number_of_results: RecommendedProducts::BaseService::NUMBER_OF_RESULTS,
        user_ids: [seller1.id],
      ).and_return(Link.where(id: products.first.id))
      product_infos = described_class.fetch_for_cart(
        purchaser:,
        cart_product_ids: [product1.id, product3.id],
        recommender_model_name:,
        limit: 5
      )

      expect(product_infos.map(&:product)).to eq([products.first])
      expect(product_infos.map(&:recommended_by).uniq).to eq([RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION])
      expect(product_infos.map(&:recommender_model_name).uniq).to eq([recommender_model_name])
      expect(product_infos.map(&:target).uniq).to eq([Product::Layout::PROFILE])
    end

    it "calls search_products with the correct arguments" do
      expect_any_instance_of(RecommendedProducts::CheckoutService).to receive(:search_products).with(
        size: 5,
        sort: ProductSortKey::FEATURED,
        user_id: [seller1.id],
        is_alive_on_profile: true,
        exclude_ids: [product1.id, product3.id, product2.id]
      ).and_call_original
      described_class.fetch_for_cart(
        purchaser:,
        cart_product_ids: [product1.id, product3.id],
        recommender_model_name:,
        limit: 5
      )
    end

    describe "affiliate recommendations" do
      let(:recommendable_product) { create(:product, :recommendable) }
      let!(:affiliate) do
        create(
          :direct_affiliate,
          seller: recommendable_product.user,
          products: [recommendable_product],
          affiliate_user: seller1
        )
      end

      context "when at least one of the creators has direct affiliate recommendations turned on" do
        before do
          seller1.update!(recommendation_type: User::RecommendationType::DIRECTLY_AFFILIATED_PRODUCTS)
        end

        it "returns the user's products and products that are directly affiliated and recommendable" do
          expect(RecommendedProductsService).to receive(:fetch).with(
            model: RecommendedProductsService::MODEL_SALES,
            ids: [product1.id, product3.id, product2.id],
            exclude_ids: [product1.id, product3.id, product2.id],
            number_of_results: RecommendedProducts::BaseService::NUMBER_OF_RESULTS,
            user_ids: nil,
          ).and_return(Link.where(id: [product2.id, recommendable_product.id]))
          product_infos = described_class.fetch_for_cart(
            purchaser:,
            cart_product_ids: [product1.id, product3.id],
            recommender_model_name:,
            limit: 5
          )
          expect(product_infos.map(&:product)).to eq([recommendable_product, products.first])
          expect(product_infos.first.affiliate_id).to eq(affiliate.external_id_numeric)
          expect(product_infos.map(&:recommended_by).uniq).to eq([RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION])
          expect(product_infos.map(&:recommender_model_name).uniq).to eq([recommender_model_name])
          expect(product_infos.map(&:target).uniq).to eq([Product::Layout::PROFILE])
        end
      end

      context "when at least one of the creators has Gumroad affiliate recommendations turned on" do
        before do
          seller1.update!(recommendation_type: User::RecommendationType::GUMROAD_AFFILIATES_PRODUCTS)
        end

        it "returns the user's products and products that are recommendable" do
          expect(RecommendedProductsService).to receive(:fetch).with(
            model: RecommendedProductsService::MODEL_SALES,
            ids: [product1.id, product3.id, product2.id],
            exclude_ids: [product1.id, product3.id, product2.id],
            number_of_results: RecommendedProducts::BaseService::NUMBER_OF_RESULTS,
            user_ids: nil,
          ).and_return(Link.where(id: [products.first.id, products.second.id, recommendable_product.id]))
          product_infos = described_class.fetch_for_cart(
            purchaser:,
            cart_product_ids: [product1.id, product3.id],
            recommender_model_name:,
            limit: 5
          )
          expect(product_infos.map(&:product)).to eq([products.first, recommendable_product])
          expect(product_infos.second.affiliate_id).to eq(affiliate.external_id_numeric)
          expect(product_infos.map(&:recommended_by).uniq).to eq([RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION])
          expect(product_infos.map(&:recommender_model_name).uniq).to eq([recommender_model_name])
          expect(product_infos.map(&:target).uniq).to eq([Product::Layout::PROFILE])
        end
      end
    end

    context "when a NSFW product is returned by the service" do
      let!(:nsfw_product) { create(:product, :recommendable, is_adult: true) }

      before do
        allow(RecommendedProductsService).to receive(:fetch).and_return(Link.where(id: nsfw_product.id))
      end

      context "when there are NSFW products in the cart" do
        let(:cart_product) do
          create(
            :product,
            user: create(:user, recommendation_type: User::RecommendationType::GUMROAD_AFFILIATES_PRODUCTS),
            is_adult: true
          )
        end
        it "includes that product in the results" do
          product_infos = described_class.fetch_for_cart(
            purchaser:,
            cart_product_ids: [cart_product.id],
            recommender_model_name:,
            limit: 5
          )
          expect(product_infos.first.product).to eq(nsfw_product)
          expect(product_infos.map(&:recommended_by).uniq).to eq([RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION])
          expect(product_infos.map(&:recommender_model_name).uniq).to eq([recommender_model_name])
          expect(product_infos.map(&:target).uniq).to eq([Product::Layout::PROFILE])
        end
      end

      context "when there aren't NSFW products in the cart" do
        let(:cart_product) do
          create(
            :product,
            user: create(:user, recommendation_type: User::RecommendationType::GUMROAD_AFFILIATES_PRODUCTS)
          )
        end

        context "when providing affiliate recommendations" do
          it "excludes the product from the results" do
            product_infos = described_class.fetch_for_cart(
              purchaser:,
              cart_product_ids: [cart_product.id],
              recommender_model_name:,
              limit: 5
            )
            expect(product_infos).to eq([])
          end
        end

        context "when not providing affiliate recommendations" do
          let(:cart_product) { create(:product, user: nsfw_product.user) }

          it "includes that product in the results" do
            product_infos = described_class.fetch_for_cart(
              purchaser:,
              cart_product_ids: [cart_product.id],
              recommender_model_name:,
              limit: 5
            )
            expect(product_infos.first.product).to eq(nsfw_product)
            expect(product_infos.map(&:recommended_by).uniq).to eq([RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION])
            expect(product_infos.map(&:recommender_model_name).uniq).to eq([recommender_model_name])
            expect(product_infos.map(&:target).uniq).to eq([Product::Layout::PROFILE])
          end
        end
      end

      context "when the product is not visible" do
        let(:product) { create(:product, :recommendable) }
        let(:banned_product) { create(:product, :recommendable, banned_at: Time.current) }
        let(:deleted_product) { create(:product, :recommendable, deleted_at: Time.current) }
        let(:purchase_disabled_product) { create(:product, :recommendable, purchase_disabled_at: Time.current) }
        let(:not_shown_on_profile_product) { create(:product, :recommendable, archived: true) }

        it "doesn't include that product in the results" do
          allow(RecommendedProductsService).to receive(:fetch).and_return(
            Link.where(
              id: [product.id, banned_product.id, deleted_product.id, purchase_disabled_product.id, not_shown_on_profile_product.id]
            )
          )
          product_infos = described_class.fetch_for_cart(
            purchaser:,
            cart_product_ids: [create(:product, user: create(:user, recommendation_type: User::RecommendationType::GUMROAD_AFFILIATES_PRODUCTS)).id],
            recommender_model_name:,
            limit: 5
          )
          expect(product_infos.map(&:product)).to eq([product])
          expect(product_infos.map(&:recommended_by).uniq).to eq([RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION])
          expect(product_infos.map(&:recommender_model_name).uniq).to eq([recommender_model_name])
          expect(product_infos.map(&:target).uniq).to eq([Product::Layout::PROFILE])
        end

        context "when the recommendation model returns fewer than the limit" do
          let!(:additional_product1) { create(:product, user: seller1) }
          let!(:additional_product2) { create(:product, user: seller1, archived: true) }
          let!(:additional_product3) { create(:product, user: seller1, deleted_at: Time.current) }

          before do
            index_model_records(Link)
          end

          it "fills out the results with the users' products" do
            expect(RecommendedProductsService).to receive(:fetch).with(
              {
                model: RecommendedProductsService::MODEL_SALES,
                ids: [product1.id, product2.id],
                exclude_ids: [product1.id, product2.id],
                number_of_results: RecommendedProducts::BaseService::NUMBER_OF_RESULTS,
                user_ids: [seller1.id],
              }
            ).and_return(Link.where(id: products.first.id))
            product_infos = described_class.fetch_for_cart(
              purchaser:,
              cart_product_ids: [product1.id],
              recommender_model_name:,
              limit: 5
            )
            expect(product_infos.map(&:product)).to eq([products.first, additional_product1])
          end
        end

        context "when a bundle is one of the associated products" do
          let!(:bundle) { create(:product, :bundle) }

          it "excludes the bundle's products from the results" do
            expect(RecommendedProductsService).to receive(:fetch).with(
              exclude_ids: [bundle.id, purchase.link.id, *bundle.bundle_products.pluck(:product_id)],
              ids: [bundle.id, purchase.link.id],
              model: RecommendedProductsService::MODEL_SALES,
              number_of_results: RecommendedProducts::BaseService::NUMBER_OF_RESULTS,
              user_ids: [bundle.user.id],
            ).and_call_original
            described_class.fetch_for_cart(
              purchaser:,
              cart_product_ids: [bundle.id],
              recommender_model_name:,
              limit: 5
            )
          end
        end
      end
    end
  end
end
