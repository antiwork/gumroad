# frozen_string_literal: true

require "spec_helper"

describe RecommendedProducts::DiscoverService do
  let(:purchaser) { create(:user) }
  let(:products) { create_list(:product, 5) }
  let(:products_relation) { Link.where(id: products.map(&:id)) }
  let(:recommender_model_name) { RecommendedProductsService::MODEL_SALES }

  before do
    products.last.update!(deleted_at: Time.current)
    products.second_to_last.update!(archived: true)
  end

  describe ".fetch" do
    it "initializes with the correct arguments" do
      expect(RecommendedProducts::DiscoverService).to receive(:new).with(
        purchaser:,
        cart_product_ids: [products.first.id],
        recommender_model_name:,
        recommended_by: RecommendationType::GUMROAD_PRODUCTS_FOR_YOU_RECOMMENDATION,
        target: Product::Layout::DISCOVER,
        limit: RecommendedProducts::BaseService::NUMBER_OF_RESULTS,
      ).and_call_original
      described_class.fetch(
        purchaser:,
        cart_product_ids: [products.first.id],
        recommender_model_name:,
      )
    end
  end

  describe "#product_infos" do
    let(:product_infos) do
      described_class.fetch(
        purchaser:,
        cart_product_ids:,
        recommender_model_name:,
      )
    end

    context "without a purchaser" do
      let(:purchaser) { nil }

      context "without card_product_ids" do
        let(:cart_product_ids) { [] }

        it "returns an empty array" do
          expect(product_infos).to eq([])
        end
      end

      context "with cart_product_ids" do
        let(:cart_product) { create(:product) }
        let(:cart_product_ids) { [cart_product.id] }

        it "returns product infos" do
          expect(RecommendedProductsService).to receive(:fetch).with(
            {
              model: RecommendedProductsService::MODEL_SALES,
              ids: [cart_product.id],
              exclude_ids: [cart_product.id],
              number_of_results: RecommendedProducts::BaseService::NUMBER_OF_RESULTS,
              user_ids: nil,
            }
          ).and_return(products_relation)
          expect(product_infos.map(&:product)).to eq(products.take(3))
          expect(product_infos.map(&:affiliate_id).uniq).to eq([nil])
          expect(product_infos.map(&:recommended_by).uniq).to eq([RecommendationType::GUMROAD_PRODUCTS_FOR_YOU_RECOMMENDATION])
          expect(product_infos.map(&:recommender_model_name).uniq).to eq([recommender_model_name])
          expect(product_infos.map(&:target).uniq).to eq([Product::Layout::DISCOVER])
        end
      end
    end

    context "with a purchaser" do
      context "when the purchaser doesn't have purchases" do
        context "without card_product_ids" do
          let(:cart_product_ids) { [] }

          it "returns an empty array" do
            expect(product_infos).to eq([])
          end
        end
      end

      context "when the purchaser has purchases" do
        let!(:purchase) { create(:purchase, purchaser:) }
        let(:cart_product_ids) { [] }

        it "returns product infos" do
          expect(RecommendedProductsService).to receive(:fetch).with(
            {
              model: RecommendedProductsService::MODEL_SALES,
              ids: [purchase.link.id],
              exclude_ids: [purchase.link.id],
              number_of_results: RecommendedProducts::BaseService::NUMBER_OF_RESULTS,
              user_ids: nil,
            }
          ).and_return(products_relation)
          expect(product_infos.map(&:product)).to eq(products.take(3))
        end

        context "when a NSFW product is returned by the service" do
          let(:nsfw_product) { create(:product, is_adult: true) }

          it "excludes that product from the results" do
            allow(RecommendedProductsService).to receive(:fetch).and_return(Link.where(id: [nsfw_product.id] + products.map(&:id)))
            expect(product_infos.map(&:product)).to eq(products.take(3))
          end
        end
      end
    end
  end
end
