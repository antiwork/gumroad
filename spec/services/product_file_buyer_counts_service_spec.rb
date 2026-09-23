# frozen_string_literal: true

require "spec_helper"

describe ProductFileBuyerCountsService do
  let(:product) { create(:product) }
  # eager: the service counts the files that exist when it runs, and the expectation below
  # reads the file's external id, so the file has to be attached before the count is taken.
  let!(:product_file) { create(:product_file, link: product) }
  let(:counts) { described_class.new(product:).counts_by_external_id }

  def buy(variants: [])
    purchase = create(:purchase, link: product)
    if variants.any?
      purchase.variant_attributes = variants
      purchase.save!
    end
    purchase
  end

  it "counts every buyer who still has access to a product-wide file" do
    3.times { buy }

    expect(counts[product_file.external_id]).to eq(3)
  end

  it "counts a membership buyer's recurring charges once" do
    buyer = create(:user)
    3.times { create(:purchase, link: product, purchaser: buyer, email: buyer.email) }

    expect(counts[product_file.external_id]).to eq(1)
  end

  it "counts a guest purchase, which carries no purchaser id" do
    purchase = create(:purchase, link: product)
    purchase.update_column(:purchaser_id, nil)

    expect(counts[product_file.external_id]).to eq(1)
  end

  it "keys the counts by the file external id the editor receives" do
    buy
    other_file = create(:product_file, link: product)
    2.times { buy }

    # Both files are product-wide, so each one is reached by every buyer.
    expect(counts).to eq(product_file.external_id => 3, other_file.external_id => 3)
  end

  it "leaves out a fully refunded buyer, who has no access to lose" do
    2.times { buy }
    create(:purchase, link: product, stripe_refunded: true)

    expect(counts[product_file.external_id]).to eq(2)
  end

  it "leaves out a charged-back buyer" do
    buy
    create(:purchase, link: product, chargeback_date: Time.current)

    expect(counts[product_file.external_id]).to eq(1)
  end

  it "leaves out a purchase that never succeeded" do
    buy
    create(:purchase, link: product, purchase_state: "failed")

    expect(counts[product_file.external_id]).to eq(1)
  end

  it "counts the purchase a bundle buyer generated for this product" do
    buy
    create(:purchase, link: product, is_bundle_product_purchase: true)

    expect(counts[product_file.external_id]).to eq(2)
  end

  context "when the file is attached to a variant" do
    let(:category) { create(:variant_category, link: product) }
    let(:variant) { create(:variant, variant_category: category) }
    let(:other_variant) { create(:variant, variant_category: category) }

    before { product_file.base_variants = [variant] }

    it "counts only the buyers of that variant" do
      2.times { buy(variants: [variant]) }
      3.times { buy(variants: [other_variant]) }
      buy

      expect(counts[product_file.external_id]).to eq(2)
    end

    it "counts a buyer holding two of the file's variants once" do
      second_variant = create(:variant, variant_category: category)
      product_file.base_variants = [variant, second_variant]

      buy(variants: [variant, second_variant])
      buy(variants: [variant])

      expect(counts[product_file.external_id]).to eq(2)
    end

    it "excludes a refunded buyer of that variant" do
      buy(variants: [variant])
      create(:purchase, link: product, variant_attributes: [variant], stripe_refunded: true)

      expect(counts[product_file.external_id]).to eq(1)
    end

    it "returns zero when nobody bought the variant" do
      2.times { buy(variants: [other_variant]) }

      expect(counts[product_file.external_id]).to eq(0)
    end

    it "still counts a product-wide file against every buyer" do
      product_wide_file = create(:product_file, link: product)
      buy(variants: [variant])
      buy(variants: [other_variant])

      expect(counts[product_wide_file.external_id]).to eq(2)
      expect(counts[product_file.external_id]).to eq(1)
    end
  end

  it "ignores a deleted file" do
    deleted_file = create(:product_file, link: product)
    buy
    deleted_file.mark_deleted!

    expect(counts).to eq(product_file.external_id => 1)
  end
end
