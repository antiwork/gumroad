# frozen_string_literal: true

require "spec_helper"

# Regression for main red build 2026-08-04: `save_files!` sets `content_updated_at` on the link
# without saving it. `update_review_stat_via_rating_change`'s first-row path used to call
# `with_lock` on the link/product itself, and Rails refuses to reload a record with unpersisted
# changes -- raising "Locking a record with unpersisted changes is not supported" the moment a
# product's first review lands right after `save_files!` touched it in the same request.
describe Product::ReviewStat, "first review on a dirty link" do
  it "creates the review stat without raising when the link has unsaved in-memory changes" do
    product = create(:product_with_files)
    product.content_updated_at = Time.current
    expect(product.changed?).to eq(true)

    purchase = create(:purchase, link: product)
    expect { create(:product_review, purchase:, rating: 4) }.not_to raise_error

    expect(product.reload.product_review_stat).to have_attributes(reviews_count: 1)
  end
end
