# frozen_string_literal: true

require "spec_helper"

describe User::ReputationSummary do
  let(:seller) { create(:user) }
  let(:product_one) { create(:product, user: seller) }
  let(:product_two) { create(:product, user: seller) }

  def create_stat(product, five: 0, four: 0, one: 0)
    total = five + four + one
    ProductReviewStat.create!(
      link: product,
      reviews_count: total,
      average_rating: total.zero? ? 0 : ((five * 5 + four * 4 + one).to_f / total).round(1),
      ratings_of_five_count: five,
      ratings_of_four_count: four,
      ratings_of_one_count: one,
    )
  end

  describe "#seller_reputation_summary" do
    context "when the flag is off" do
      it "returns nil even when thresholds are met" do
        create_stat(product_one, five: 8)
        create_stat(product_two, four: 4)

        expect(seller.seller_reputation_summary).to be_nil
      end
    end

    context "when the flag is on" do
      before { Feature.activate_user(:seller_reputation_summary, seller) }

      it "sums per-star counts across products and weights the average by review count" do
        create_stat(product_one, five: 8)
        create_stat(product_two, four: 3, one: 1)

        expect(seller.seller_reputation_summary).to eq(
          average: ((8 * 5 + 3 * 4 + 1).to_f / 12).round(1),
          count: 12,
          products_count: 2,
        )
      end

      it "returns nil below #{User::ReputationSummary::MIN_REVIEWS} reviews" do
        create_stat(product_one, five: 5)
        create_stat(product_two, four: 4)

        expect(seller.seller_reputation_summary).to be_nil
      end

      it "returns nil when reviews span fewer than #{User::ReputationSummary::MIN_PRODUCTS} products" do
        create_stat(product_one, five: 15)

        expect(seller.seller_reputation_summary).to be_nil
      end

      it "skips products that opted out of displaying reviews" do
        create_stat(product_one, five: 8)
        create_stat(product_two, four: 4)
        opted_out = create(:product, user: seller, display_product_reviews: false)
        create_stat(opted_out, one: 50)

        expect(seller.seller_reputation_summary).to eq(average: 4.7, count: 12, products_count: 2)
      end

      it "skips deleted products" do
        create_stat(product_one, five: 8)
        create_stat(product_two, four: 4)
        deleted = create(:product, user: seller, deleted_at: Time.current)
        create_stat(deleted, one: 50)

        expect(seller.seller_reputation_summary).to eq(average: 4.7, count: 12, products_count: 2)
      end

      it "skips draft products" do
        create_stat(product_one, five: 8)
        create_stat(product_two, four: 4)
        draft = create(:product, user: seller, purchase_disabled_at: nil, draft: true)
        create_stat(draft, one: 50)

        expect(seller.seller_reputation_summary).to eq(average: 4.7, count: 12, products_count: 2)
      end

      it "does not count another seller's products" do
        create_stat(product_one, five: 8)
        create_stat(product_two, four: 4)
        create_stat(create(:product), one: 50)

        expect(seller.seller_reputation_summary).to eq(average: 4.7, count: 12, products_count: 2)
      end

      it "excludes the given product and its reviews" do
        create_stat(product_one, five: 8)
        create_stat(product_two, four: 4)
        third = create(:product, user: seller)
        create_stat(third, five: 4)

        expect(seller.seller_reputation_summary(exclude_product: third)).to eq(average: 4.7, count: 12, products_count: 2)
      end

      it "returns nil when the exclusion drops the seller below the thresholds" do
        create_stat(product_one, five: 8)
        create_stat(product_two, four: 4)

        expect(seller.seller_reputation_summary(exclude_product: product_one)).to be_nil
      end
    end
  end
end
