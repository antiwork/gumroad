# frozen_string_literal: true

require "spec_helper"

describe ProductReviewStat do
  describe "#rating_counts" do
    it "returns counts of ratings" do
      review_stat = build(:product_review_stat, ratings_of_one_count: 7, ratings_of_three_count: 11)
      expect(review_stat.rating_counts).to eq(1 => 7, 2 => 0, 3 => 11, 4 => 0, 5 => 0)
    end
  end

  describe "#rating_percentages" do
    it "returns zero when there are no ratings" do
      review_stat = build(:product_review_stat)
      expect(review_stat.rating_percentages).to eq(1 => 0, 2 => 0, 3 => 0, 4 => 0, 5 => 0)
    end

    it "returns percentages" do
      review_stat = build(:product_review_stat, reviews_count: 4, ratings_of_one_count: 1, ratings_of_three_count: 3)
      expect(review_stat.rating_percentages).to eq(1 => 25, 2 => 0, 3 => 75, 4 => 0, 5 => 0)
    end

    it "adjusts non-integer values to total 100" do
      review_stat = build(
        :product_review_stat,
        reviews_count: 4 + 3 + 7 + 12 + 428,
        ratings_of_one_count: 4,
        ratings_of_two_count: 3,
        ratings_of_three_count: 7,
        ratings_of_four_count: 12,
        ratings_of_five_count: 428
      )
      expect(review_stat.rating_percentages).to eq(1 => 1, 2 => 1, 3 => 1, 4 => 3, 5 => 94)
    end

    it "favors rounding percentages for higher star ratings if there are ties" do
      review_stat = build(
        :product_review_stat,
        reviews_count: 3,
        ratings_of_one_count: 1,
        ratings_of_three_count: 1,
        ratings_of_five_count: 1
      )
      expect(review_stat.rating_percentages).to eq(1 => 33, 2 => 0, 3 => 33, 4 => 0, 5 => 34)
    end
  end

  describe "#update_with_added_rating" do
    it "correctly updates the target & derived columns" do
      review_stat = create(:product_review_stat)
      review_stat.update_with_added_rating(2)
      expect(review_stat.attributes).to include(
        "ratings_of_one_count" => 0,
        "ratings_of_two_count" => 1,
        "ratings_of_three_count" => 0,
        "ratings_of_four_count" => 0,
        "ratings_of_five_count" => 0,
        "reviews_count" => 1,
        "average_rating" => 2.0,
      )

      review_stat.update_with_added_rating(4)
      review_stat.update_with_added_rating(2)
      expect(review_stat.attributes).to include(
        "ratings_of_one_count" => 0,
        "ratings_of_two_count" => 2,
        "ratings_of_three_count" => 0,
        "ratings_of_four_count" => 1,
        "ratings_of_five_count" => 0,
        "reviews_count" => 3,
        "average_rating" => 2.7,
      )
    end
  end

  describe "#update_with_changed_rating" do
    it "correctly updates the targets & derived columns" do
      review_stat = create(:product_review_stat, ratings_of_five_count: 3)
      review_stat.update_with_changed_rating(5, 4)
      expect(review_stat.attributes).to include(
        "ratings_of_one_count" => 0,
        "ratings_of_two_count" => 0,
        "ratings_of_three_count" => 0,
        "ratings_of_four_count" => 1,
        "ratings_of_five_count" => 2,
        "reviews_count" => 3,
        "average_rating" => 4.7,
      )
    end
  end

  describe "#update_with_removed_rating" do
    it "correctly updates the targets & derived columns" do
      review_stat = create(:product_review_stat, ratings_of_four_count: 1, ratings_of_five_count: 2)
      review_stat.update_with_removed_rating(5)
      expect(review_stat.attributes).to include(
        "ratings_of_one_count" => 0,
        "ratings_of_two_count" => 0,
        "ratings_of_three_count" => 0,
        "ratings_of_four_count" => 1,
        "ratings_of_five_count" => 1,
        "reviews_count" => 2,
        "average_rating" => 4.5,
      )
    end
  end

  describe "#update_ratings" do
    it "updates reviews_count and average_rating appropriately" do
      review_stat = create(:product_review_stat)
      review_stat.send(:update_ratings, "
        ratings_of_one_count = 5,
        ratings_of_two_count = 10,
        ratings_of_three_count = 20,
        ratings_of_four_count = 60,
        ratings_of_five_count = 100
      ")
      expect(review_stat.attributes).to include(
        "ratings_of_one_count" => 5,
        "ratings_of_two_count" => 10,
        "ratings_of_three_count" => 20,
        "ratings_of_four_count" => 60,
        "ratings_of_five_count" => 100,
        "reviews_count" => 195,
        "average_rating" => 4.2
      )
    end
  end

  it "is updated after a purchase is fully refunded", :vcr do
    product = create(:product)
    purchase = create(:purchase_in_progress, link: product, chargeable: create(:chargeable))
    purchase.process!
    purchase.update_balance_and_mark_successful!

    create(:product_review, purchase: create(:purchase, link: product), rating: 1)
    create(:product_review, purchase: create(:purchase, link: product), rating: 5)
    create(:product_review, purchase:, rating: 1)

    review_stat = product.reload.product_review_stat
    expect(review_stat.attributes).to include(
      "ratings_of_one_count" => 2,
      "ratings_of_two_count" => 0,
      "ratings_of_three_count" => 0,
      "ratings_of_four_count" => 0,
      "ratings_of_five_count" => 1,
      "reviews_count" => 3,
      "average_rating" => 2.3
    )

    purchase.refund_and_save!(create(:admin_user).id)

    expect(review_stat.reload.attributes).to include(
      "ratings_of_one_count" => 1,
      "ratings_of_two_count" => 0,
      "ratings_of_three_count" => 0,
      "ratings_of_four_count" => 0,
      "ratings_of_five_count" => 1,
      "reviews_count" => 2,
      "average_rating" => 3.0
    )
  end
end
