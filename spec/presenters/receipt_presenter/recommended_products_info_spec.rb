# frozen_string_literal: true

require "spec_helper"

describe ReceiptPresenter::RecommendedProductsInfo do
  let(:purchaser) { create(:user) }
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller, name: "Digital product") }
  let(:purchase) do
    create(
      :purchase,
      link: product,
      seller:,
      price_cents: 1_499,
      created_at: DateTime.parse("January 1, 2023")
    )
  end
  let(:recommended_products_info) { described_class.new(chargeable) }

  RSpec.shared_examples "chargeable" do
    it "returns correct title" do
      expect(recommended_products_info.title).to eq("Customers who bought this item also bought")
    end

    describe "#products" do
      RSpec.shared_examples "doesn't return products" do
        it "doesn't return products" do
          expect(RecommendedProductsService).not_to receive(:for_checkout)
          expect(recommended_products_info.products).to eq([])
          expect(recommended_products_info.present?).to eq(false)
        end
      end

      context "when the purchase doesn't have a purchaser" do
        it_behaves_like "doesn't return products"
      end

      context "when the purchase has a purchaser" do
        before do
          purchase.update!(purchaser:)
        end

        context "when the feature is active" do
          let(:recommendable_product) { create(:product, :recommendable, name: "Recommended product") }
          let!(:affiliate) do
            create(
              :direct_affiliate,
              seller: recommendable_product.user,
              products: [recommendable_product], affiliate_user: create(:user)
            )
          end

          before do
            seller.update!(recommendation_type: User::RecommendationType::GUMROAD_AFFILIATES_PRODUCTS)
          end

          context "with a regular purchase" do
            it "calls RecommendedProductsService with correct args" do
              expect(RecommendedProducts::CheckoutService).to receive(:fetch_for_receipt).with(
                purchaser: purchase.purchaser,
                receipt_product_ids: [purchase.link.id],
                recommender_model_name: "sales",
                limit: ReceiptPresenter::RecommendedProductsInfo::RECOMMENDED_PRODUCTS_LIMIT,
              ).and_call_original
              expect(RecommendedProductsService).to receive(:fetch).with(
                {
                  model: "sales",
                  ids: [purchase.link.id],
                  exclude_ids: [purchase.link.id],
                  number_of_results: RecommendedProducts::BaseService::NUMBER_OF_RESULTS,
                  user_ids: nil,
                }
              ).and_return(Link.where(id: [recommendable_product.id]))

              expect(recommended_products_info.products.size).to eq(1)
              expect(recommended_products_info.present?).to eq(true)
              product_card = recommended_products_info.products.first
              expect(product_card[:name]).to eq(recommendable_product.name)
              expect(product_card[:url]).to include("affiliate_id=#{seller.global_affiliate.external_id_numeric}")
              expect(product_card[:url]).to include("layout=profile")
              expect(product_card[:url]).to include("recommended_by=receipt")
              expect(product_card[:url]).to include("recommender_model_name=sales")
            end
          end

          context "with a bundle purchase" do
            let(:purchase) { create(:purchase, link: create(:product, :bundle)) }

            before do
              purchase.create_artifacts_and_send_receipt!
            end

            it "calls RecommendedProductsService with correct args" do
              expect(RecommendedProducts::CheckoutService).to receive(:fetch_for_receipt).with(
                purchaser: purchase.purchaser,
                receipt_product_ids: [purchase.link_id] + purchase.link.bundle_products.map(&:product_id),
                recommender_model_name: "sales",
                limit: ReceiptPresenter::RecommendedProductsInfo::RECOMMENDED_PRODUCTS_LIMIT,
              ).and_call_original
              expect(recommended_products_info.products).to eq([])
              expect(recommended_products_info.present?).to eq(false)
            end
          end
        end
      end
    end
  end

  describe "for Purchase" do
    let(:chargeable) { purchase }

    it_behaves_like "chargeable"
  end

  describe "for Charge", :vcr do
    let(:charge) { create(:charge, seller:, purchases: [purchase]) }
    let!(:order) { charge.order }
    let(:chargeable) { charge }

    before do
      order.purchases << purchase
    end

    it_behaves_like "chargeable"

    context "with multiple purchases" do
      let(:another_product) { create(:product, user: seller) }
      let(:another_purchase) { create(:purchase, link: another_product, seller:) }

      let(:recommendable_product) { create(:product, :recommendable, name: "Recommended product") }
      let!(:affiliate) do
        create(
          :direct_affiliate,
          seller: recommendable_product.user,
          products: [recommendable_product], affiliate_user: create(:user)
        )
      end

      before do
        purchase.update!(purchaser:)
        another_purchase.update!(purchaser:)
        seller.update!(recommendation_type: User::RecommendationType::GUMROAD_AFFILIATES_PRODUCTS)
        charge.purchases << another_purchase
        order.purchases << another_purchase
      end

      describe "#products" do
        it "calls RecommendedProductsService with correct args" do
          expect(RecommendedProducts::CheckoutService).to receive(:fetch_for_receipt).with(
            purchaser: purchase.purchaser,
            receipt_product_ids: [purchase.link_id, another_purchase.link_id],
            recommender_model_name: "sales",
            limit: ReceiptPresenter::RecommendedProductsInfo::RECOMMENDED_PRODUCTS_LIMIT,
          ).and_call_original
          expect(recommended_products_info.products).to eq([])
          expect(recommended_products_info.present?).to eq(false)
        end
      end
    end
  end
end
