# frozen_string_literal: true

require "spec_helper"

describe Purchase, "product affiliate assignment" do
  it "keeps repeated global affiliate assignments idempotent" do
    product = create(:product)
    affiliate = create(:user).global_affiliate
    purchase = build(:purchase, link: product, affiliate:)

    2.times { purchase.send(:create_product_affiliate) }

    expect(ProductAffiliate.where(affiliate:, product:).count).to eq(1)
  end
end
