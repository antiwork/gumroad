# frozen_string_literal: true

require "spec_helper"

describe Product::Recommendations, :elasticsearch_wait_for_refresh do
  before do
    @product = create(:product, user: create(:compliant_user, name: "Some creator person"), taxonomy: create(:taxonomy))
  end

  it "is true if has recent sale" do
    create(:purchase, :with_review, link: @product, created_at: 1.week.ago)
    expect(@product.recommendable?).to be(true)
  end

  it "is true if no recent sale" do
    create(:purchase, :with_review, link: @product, created_at: 4.months.ago)
    expect(@product.recommendable?).to be(true)
  end

  it "is true even if the product is rated to be adult" do
    create(:purchase, :with_review, link: @product, created_at: 1.week.ago)
    @product.update_attribute(:name, "nsfw")

    expect(@product.recommendable?).to be(true)
  end

  it "is true if it displays product reviews" do
    create(:purchase, :with_review, link: @product, created_at: 1.month.ago)
    expect(@product.recommendable?).to be(true)
  end

  it "is false if it does not display product reviews" do
    create(:purchase, :with_review, link: @product, created_at: 1.month.ago)
    @product.update_attribute(:display_product_reviews, false)

    expect(@product.recommendable_reasons[:reviews_displayed]).to be(false)
    expect(@product.recommendable_reasons.except(:reviews_displayed).values).to all(be true)
    expect(@product.recommendable?).to be(false)
  end

  it "is false if no sale made" do
    expect(@product.recommendable_reasons[:sale_made]).to be(false)
    expect(@product.recommendable_reasons.except(:sale_made).values).to all(be true)
    expect(@product.recommendable?).to be(false)
  end

  it "is false if there are no non-refunded sales" do
    purchase = create(:purchase, :with_review, link: @product, created_at: 1.week.ago)
    expect(@product.recommendable_reasons[:sale_made]).to be(true)
    expect(@product.recommendable?).to be(true)

    purchase.update!(stripe_refunded: true)
    expect(@product.reload.recommendable_reasons[:sale_made]).to be(false)
    expect(@product.recommendable_reasons.except(:sale_made).values).to all(be true)
    expect(@product.recommendable?).to be(false)
  end

  context "when taxonomy is not set" do
    before do
      @product.update_attribute(:taxonomy, nil)
      create(:purchase, :with_review, link: @product, created_at: 1.week.ago)
    end

    it "is false" do
      expect(@product.recommendable_reasons[:taxonomy_filled]).to be(false)
      expect(@product.recommendable_reasons.except(:taxonomy_filled).values).to all(be true)
      expect(@product.recommendable?).to be(false)
    end
  end

  it "is true if it has a review" do
    create(:purchase, :with_review, link: @product, created_at: 1.week.ago)

    expect(@product.recommendable?).to be(true)
  end

  it "is true if does not have any review" do
    create(:purchase, link: @product, created_at: 1.week.ago)

    expect(@product.recommendable?).to be(true)
  end

  it "is false if item is out of stock" do
    @product.update_attribute(:max_purchase_count, 1)
    create(:purchase, :with_review, link: @product, created_at: 1.week.ago)

    expect(@product.recommendable_reasons[:not_sold_out]).to be(false)
    expect(@product.recommendable_reasons.except(:not_sold_out).values).to all(be true)
    expect(@product.recommendable?).to be(false)
  end

  it "is false if item is in stock" do
    @product.update_attribute(:max_purchase_count, 2)
    create(:purchase, :with_review, link: @product, created_at: 1.week.ago)

    expect(@product.recommendable_reasons[:not_sold_out]).to be(true)
    expect(@product.recommendable?).to be(true)
  end

  it "is false it is not alive" do
    allow(@product).to receive(:alive?).and_return(false)
    expect(@product.recommendable_reasons[:alive]).to be(false)
    expect(@product.recommendable?).to be(false)
  end

  it "is false if item is archived" do
    allow(@product).to receive(:archived?).and_return(true)
    expect(@product.recommendable_reasons[:not_archived]).to be(false)
    expect(@product.recommendable?).to be(false)
  end

  context "when product is recommendable" do
    before { @product = create(:product, :recommendable) }

    it "returns all recommendable_reason" do
      expect(@product.recommendable_reasons.values).to all(be true)
    end
  end
end
