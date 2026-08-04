# frozen_string_literal: true

require "spec_helper"

describe Product::ReviewStat, "dirty link repro" do
  it "does not raise when the link has unsaved changes and no review stat yet" do
    product = create(:product)
    product.content_updated_at = Time.current # simulate save_files! setting this without persisting
    expect(product.changed?).to eq(true)

    expect { product.update_review_stat_via_rating_change(nil, 5) }.not_to raise_error
  end
end
