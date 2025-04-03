# frozen_string_literal: true

require "spec_helper"

describe Product::ReviewStat do
  before do
    @product = create(:product)
  end

  context "when the product_review_stat record exists" do
    before do
      purchase_1 = create(:purchase, link: @product)
      @review_1 = create(:product_review, purchase: purchase_1, rating: 3)
      purchase_2 = create(:purchase, link: @product)
      @review_2 = create(:product_review, purchase: purchase_2, rating: 1)
      purchase_3 = create(:purchase, link: @product)
      @review_3 = create(:product_review, purchase: purchase_3, rating: 1)

      @review_stat = @product.reload.product_review_stat
      @expected_reviews_count = 3
      @expected_average_rating = ((@review_1.rating + @review_2.rating + @review_3.rating).to_f / 3).round(1)
    end

    describe "#update_review_stat_via_rating_change & #update_review_stat_via_purchase_changes" do
      it "computes reviews_count & average_rating for the product correctly" do
        expect(@review_stat.reviews_count).to eq(@expected_reviews_count)
        expect(@review_stat.average_rating).to eq(@expected_average_rating)
        expect(@review_stat.ratings_of_one_count).to eq(2)
        expect(@review_stat.ratings_of_three_count).to eq(1)
        expect(@review_stat.ratings_of_four_count).to eq(0)
      end

      it "computes aggregate fields correctly for a new rating added" do
        new_purchase = create(:purchase, link: @product)
        new_review = create(:product_review, purchase: new_purchase, rating: 5)
        expected_average_rating = ((@review_1.rating + @review_2.rating + @review_3.rating + new_review.rating).to_f / 4).round(1)

        expect(@review_stat.reviews_count).to eq(@expected_reviews_count + 1)
        expect(@review_stat.average_rating).to eq(expected_average_rating)
        expect(@review_stat.ratings_of_five_count).to eq(1)
      end

      it "computes aggregate fields correctly for an existing rating being updated" do
        @review_3.update!(rating: 4)
        expected_average_rating = ((@review_1.rating + @review_2.rating + @review_3.rating).to_f / 3).round(1)

        expect(@review_stat.reviews_count).to eq(@expected_reviews_count)
        expect(@review_stat.average_rating).to eq(expected_average_rating)
        expect(@review_stat.ratings_of_four_count).to eq(1)
      end

      it "computes aggregate fields correctly for an existing rating becoming invalid due to a refund" do
        purchase = create(:purchase, link: @product)
        create(:product_review, purchase:, rating: 1)

        expect(@review_stat.reviews_count).to eq(@expected_reviews_count + 1)
        expect(@review_stat.average_rating).to eq(((@review_1.rating + @review_2.rating + @review_3.rating + 1).to_f / 4).round(1))

        purchase.update!(stripe_refunded: true)

        expect(@review_stat.reviews_count).to eq(@expected_reviews_count)
        expect(@review_stat.average_rating).to eq(@expected_average_rating)
        expect(@review_stat.ratings_of_one_count).to eq(2)
      end

      it "computes aggregate fields correctly for an existing rating becoming invalid due to purchase state" do
        purchase = create(:purchase, link: @product)
        create(:product_review, purchase:, rating: 1)

        expect(@review_stat.reviews_count).to eq(@expected_reviews_count + 1)
        expect(@review_stat.average_rating).to eq(((@review_1.rating + @review_2.rating + @review_3.rating + 1).to_f / 4).round(1))

        purchase.update!(purchase_state: "failed")

        expect(@review_stat.reviews_count).to eq(@expected_reviews_count)
        expect(@review_stat.average_rating).to eq(@expected_average_rating)
        expect(@review_stat.ratings_of_one_count).to eq(2)
      end

      it "computes aggregate fields correctly for an existing rating becoming invalid due to a charge back" do
        purchase = create(:purchase, link: @product)
        create(:product_review, purchase:, rating: 1)

        expect(@review_stat.reviews_count).to eq(@expected_reviews_count + 1)
        expect(@review_stat.average_rating).to eq(((@review_1.rating + @review_2.rating + @review_3.rating + 1).to_f / 4).round(1))

        purchase.update!(chargeback_date: Date.today)

        expect(@review_stat.reviews_count).to eq(@expected_reviews_count)
        expect(@review_stat.average_rating).to eq(@expected_average_rating)
        expect(@review_stat.ratings_of_one_count).to eq(2)
      end

      it "computes aggregate fields correctly for an existing rating for a free purchase becoming invalid due to a revoke" do
        purchase = create(:free_purchase, link: @product)
        create(:product_review, purchase:, rating: 1)

        expect(@review_stat.reviews_count).to eq(@expected_reviews_count + 1)
        expect(@review_stat.average_rating).to eq(((@review_1.rating + @review_2.rating + @review_3.rating + 1).to_f / 4).round(1))

        purchase.update!(is_access_revoked: true)

        expect(@review_stat.reviews_count).to eq(@expected_reviews_count)
        expect(@review_stat.average_rating).to eq(@expected_average_rating)
        expect(@review_stat.ratings_of_one_count).to eq(2)
      end

      it "computes aggregate fields correctly for an existing rating for a paid purchase NOT becoming invalid due to a revoke" do
        purchase = create(:purchase, link: @product)
        create(:product_review, purchase:, rating: 1)

        expect(@review_stat.reviews_count).to eq(@expected_reviews_count + 1)
        expect(@review_stat.average_rating).to eq(((@review_1.rating + @review_2.rating + @review_3.rating + 1).to_f / 4).round(1))

        purchase.update!(is_access_revoked: true)

        expect(@review_stat.reviews_count).to eq(@expected_reviews_count + 1)
        expect(@review_stat.average_rating).to eq(((@review_1.rating + @review_2.rating + @review_3.rating + 1).to_f / 4).round(1))
      end
    end
    describe "#average_rating" do
      it "returns the average rating based on all the reviews from successful purchases of the product" do
        expect(@product.average_rating).to eq(@expected_average_rating)
      end
    end

    describe "#rating_counts" do
      it "returns a list of counts of product reviews by rating" do
        expected = { 1 => 2, 2 => 0, 3 => 1, 4 => 0, 5 => 0 }
        expect(@product.rating_counts).to eq(expected)
      end
    end

    describe "#reviews_count" do
      it "returns the count of reviews from successful purchases" do
        expect(@product.reviews_count).to eq(3)
      end
    end

    describe "#sync_review_stat & #generate_review_stat_attributes" do
      it "recomputes reviews_count & average_rating for the product correctly" do
        @review_stat.update_columns(
          reviews_count: 0,
          average_rating: 0,
          ratings_of_one_count: 0,
          ratings_of_three_count: 0,
          ratings_of_four_count: 0,
        )
        expect(@product).to receive(:generate_review_stat_attributes).and_call_original
        @product.sync_review_stat

        expect(@review_stat.reviews_count).to eq(@expected_reviews_count)
        expect(@review_stat.average_rating).to eq(@expected_average_rating)
        expect(@review_stat.ratings_of_one_count).to eq(2)
        expect(@review_stat.ratings_of_three_count).to eq(1)
        expect(@review_stat.ratings_of_four_count).to eq(0)
      end

      it "creates product_review_stat when there are reviews & no product_review_stat" do
        @product.product_review_stat.destroy
        @product.reload
        @product.sync_review_stat
        expect(@product.product_review_stat).to be_present
        expect(@product.product_review_stat.reviews_count).to eq(@expected_reviews_count)
      end

      it "doesn't create product_review_stat when there are no reviews & no product_review_stat" do
        product = create(:product)
        product.sync_review_stat
        expect(product.product_review_stat).to be_nil
      end

      it "resets product_review_stat when there are no reviews" do
        product = create(:product)
        product.create_product_review_stat(
          reviews_count: 123,
          average_rating: 2,
          ratings_of_one_count: -1,
        )
        product.sync_review_stat
        expect(product.product_review_stat.reviews_count).to eq(0)
        expect(product.product_review_stat.average_rating).to eq(0.0)
        expect(product.product_review_stat.ratings_of_one_count).to eq(0)
      end
    end
  end

  context "when the product_review_stat record does not exist" do
    describe "#average_rating" do
      it "returns default value" do
        expect(@product.average_rating).to eq(0.0)
      end
    end

    describe "#rating_counts" do
      it "returns default value" do
        expect(@product.rating_counts).to eq({ 1 => 0, 2 => 0, 3 => 0, 4 => 0, 5 => 0 })
      end
    end

    describe "#reviews_count" do
      it "returns default value" do
        expect(@product.reviews_count).to eq(0)
      end
    end
  end

  # There's currently no codepath to uncount (remove) a rating, unrelated to the purchase state changing
  it "#update_review_stat_via_rating_change allows to uncount a rating" do
    product = create(:product)
    purchase = create(:purchase, link: product)
    create(:product_review, purchase:, rating: 2)
    product.update_review_stat_via_rating_change(2, nil)
    expect(product.average_rating).to eq(0)
  end

  describe "#update_review_stat_via_purchase_changes" do
    # There's currently no production codepath to re-count a previously uncounted rating, but we support it anyway
    it "allows to count a previously uncounted rating" do
      product = create(:product)
      purchase = create(:purchase, link: product)
      create(:product_review, purchase:, rating: 2)
      purchase.update!(stripe_refunded: true)
      expect(product.average_rating).to eq(0)
      purchase.update!(stripe_refunded: false)
      expect(product.average_rating).to eq(2)
    end

    it "does nothing if there are no purchase changes" do
      product = create(:product)
      purchase = create(:purchase, link: product)
      review = create(:product_review, purchase:, rating: 2)
      review_stat_attributes = product.product_review_stat.attributes
      product.update_review_stat_via_purchase_changes({}, product_review: review)
      expect(product.product_review_stat.reload.attributes).to eq(review_stat_attributes)
    end

    it "does nothing when updating a subsequent subscription purchase is updated" do
      purchase = create(:membership_purchase)
      product = purchase.link
      create(:product_review, purchase:, rating: 2)
      review_stat_attributes = product.product_review_stat.attributes

      # test that a subsequent valid purchase doesn't change the product_review_stat
      purchase_2 = create(:membership_purchase, link: product, subscription: purchase.reload.subscription)
      expect(product.product_review_stat.reload.attributes).to eq(review_stat_attributes)
      # test that invalidating a subsequent purchase doesn't change the product_review_stat
      purchase_2.update!(stripe_refunded: true)
      expect(product.product_review_stat.reload.attributes).to eq(review_stat_attributes)
      purchase_2.update!(stripe_refunded: false)
      expect(product.product_review_stat.reload.attributes).to eq(review_stat_attributes)
    end
  end
end
