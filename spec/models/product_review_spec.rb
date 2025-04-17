# frozen_string_literal: true

require "spec_helper"

describe ProductReview do
  it "enforces the rating to lie within a specific range" do
    ProductReview::PRODUCT_RATING_RANGE.each do |rating|
      expect(create(:product_review, rating:)).to be_valid
    end

    product_review = build(:product_review, rating: 0)
    expect(product_review).to be_invalid
    expect(product_review.errors[:rating].first).to eq("Invalid product rating.")

    product_review = build(:product_review, rating: 6)
    expect(product_review).to be_invalid
    expect(product_review.errors[:rating].first).to eq("Invalid product rating.")
  end

  it "mandates the presence of a purchase and a product" do
    product_review = build(:product_review, purchase: nil, rating: 2)
    expect(product_review).to be_invalid
    expect(product_review.errors[:purchase].first).to eq("can't be blank")

    product_review.purchase = create(:purchase)
    expect(product_review).to be_invalid
    expect(product_review.errors[:link].first).to eq("can't be blank")

    product_review.link = product_review.purchase.link
    expect(product_review).to be_valid
  end

  it "disallows multiple records with the same purchase_id" do
    purchase = create(:purchase)
    expect(create(:product_review, purchase:, rating: 3)).to be_valid
    product_review = build(:product_review, purchase:, rating: 2)
    expect(product_review).to be_invalid
    expect(product_review.errors[:purchase_id].first).to eq("has already been taken")
  end

  context "after creation" do
    it "updates the matching product_review_stat" do
      purchase = create(:purchase)
      product_review = build(:product_review, purchase:)
      expect(product_review.link.product_review_stat).not_to be_present
      expect(product_review.link).to receive(:update_review_stat_via_rating_change).with(nil, 1).and_call_original
      product_review.save!
      expect(product_review.link.product_review_stat).to be_present
    end
  end

  context "after update" do
    it "updates the matching product_review_stat" do
      product_review = create(:product_review)
      expect(product_review.link.product_review_stat.average_rating).to eq(1)
      expect(product_review.link).to receive(:update_review_stat_via_rating_change).with(1, 3).and_call_original
      product_review.update!(rating: 3)
      expect(product_review.link.product_review_stat.average_rating).to eq(3)
    end
  end

  it "calls link.update_review_stat_via_rating_change to update the product reviews stat after a rating is updated" do
    product_review = create(:product_review)
    expect(product_review.link).to receive(:update_review_stat_via_rating_change).with(1, 2)
    product_review.rating = product_review.rating.succ
    product_review.save!
  end

  it "can't be created for an invalid purchase" do
    purchase = create(:refunded_purchase)
    expect { create(:product_review, purchase:) }.to raise_error(ProductReview::RestrictedOperationError)
  end

  context "purchase doesn't allow review to be counted" do
    let(:product_review) { create(:product_review) }

    before { product_review.purchase.update_columns(stripe_refunded: true) }

    it "rating can't be updated" do
      expect { product_review.update!(rating: 3) }.to raise_error(ProductReview::RestrictedOperationError)
    end

    it "deleted_at can be updated" do
      expect { product_review.update!(deleted_at: Time.current) }.not_to raise_error
    end
  end

  it "can't be destroyed" do
    product_review = create(:product_review)
    expect { product_review.destroy }.to raise_error(ProductReview::RestrictedOperationError)
  end

  it "validates the message against adult keywords" do
    product_review = build(:product_review, message: "saucy abs punch")
    expect(product_review).to_not be_valid
    expect(product_review.errors.full_messages).to eq(["Adult keywords are not allowed"])
  end

  describe ".visible_on_product_page" do
    let!(:only_has_message) { create(:product_review, message: "has_message") }
    let!(:only_has_approved_video) do
      create(
        :product_review,
        message: nil,
        videos: [build(:product_review_video, :approved)]
      )
    end
    let!(:only_has_pending_video) do
      create(
        :product_review,
        message: nil,
        videos: [build(:product_review_video, :pending_review)]
      )
    end
    let!(:only_has_deleted_approved_video) do
      create(
        :product_review,
        message: nil,
        videos: [build(:product_review_video, :approved, deleted_at: Time.current)]
      )
    end
    let!(:no_message_or_video) { create(:product_review, message: nil, videos: []) }

    it "includes reviews with has_message: true" do
      expect(ProductReview.visible_on_product_page.pluck(:id))
        .to contain_exactly(only_has_message.id, only_has_approved_video.id)
    end
  end
end
