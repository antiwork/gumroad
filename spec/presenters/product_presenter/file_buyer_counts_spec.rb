# frozen_string_literal: true

require "spec_helper"

describe ProductPresenter::FileBuyerCounts do
  # $0 purchases throughout: the count is about who can reach the file, not what they
  # paid, and a free purchase lands in the same success states a paid one does.
  let(:product) { create(:product_with_pdf_file) }
  let(:file) { product.product_files.alive.first }
  let(:purchase_attrs) { { link: product, price_cents: 0 } }

  subject(:counts) { described_class.new(product:).props }

  it "counts nobody for a file nobody has bought" do
    expect(counts).to eq(file.external_id => 0)
  end

  it "counts every buyer of the product against a file with no version scoping" do
    create_list(:purchase, 3, **purchase_attrs)

    expect(counts).to eq(file.external_id => 3)
  end

  it "counts a free (not charged) purchase and a gift receiver, which both hold access" do
    create(:purchase, **purchase_attrs)
    create(:purchase, **purchase_attrs, purchase_state: "not_charged")
    create(:purchase, :gift_receiver, **purchase_attrs)

    expect(counts).to eq(file.external_id => 3)
  end

  it "leaves out purchases that never completed, were fully refunded, or were charged back" do
    create(:purchase, **purchase_attrs)
    create(:purchase, **purchase_attrs, purchase_state: "failed")
    create(:purchase, **purchase_attrs, purchase_state: "in_progress")
    create(:purchase, **purchase_attrs, stripe_refunded: true)
    create(:purchase, **purchase_attrs, chargeback_date: Time.current)

    expect(counts).to eq(file.external_id => 1)
  end

  context "when a file sits only in some versions of the product" do
    let(:variant_category) { create(:variant_category, link: product) }
    let!(:version_with_file) { create(:variant, variant_category:, name: "Version 1") }
    let!(:other_version) { create(:variant, variant_category:, name: "Version 2") }
    let!(:product_level_file) { create(:product_file, link: product) }

    before do
      version_with_file.product_files = [file]
      create(:purchase, **purchase_attrs, variant_attributes: [version_with_file])
      create_list(:purchase, 2, **purchase_attrs, variant_attributes: [other_version])
      # A buyer with no version at all can still reach an unscoped file.
      create(:purchase, **purchase_attrs)
    end

    it "counts only the buyers holding a version that carries the file" do
      expect(counts[file.external_id]).to eq(1)
    end

    it "still counts every buyer against a file with no version scoping" do
      expect(counts[product_level_file.external_id]).to eq(4)
    end

    it "does not count a buyer twice when they hold two versions carrying the file" do
      second_category = create(:variant_category, link: product)
      second_version = create(:variant, variant_category: second_category, name: "Version 3")
      second_version.product_files = [file]
      create(:purchase, **purchase_attrs, variant_attributes: [version_with_file, second_version])

      expect(counts[file.external_id]).to eq(2)
    end
  end

  it "ignores buyers of a file that is no longer alive" do
    create(:purchase, **purchase_attrs)
    file.update!(deleted_at: Time.current)

    expect(counts).to eq({})
  end
end
