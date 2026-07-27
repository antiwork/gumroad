# frozen_string_literal: true

require "spec_helper"

describe Product::EditorRevision do
  let(:product) { create(:product) }

  describe ".current" do
    it "is stable across repeated calls on unchanged state" do
      # The token gates deletions, so a token that drifts on identical state
      # would reject legitimate saves at random — the exact failure mode that
      # got the product-wide guard in #6245 switched off.
      first = described_class.current(product)
      expect(described_class.current(product)).to eq(first)
      expect(described_class.current(product)).to eq(first)
    end

    it "returns a compact hex token, not raw state" do
      token = described_class.current(product)
      expect(token).to match(/\A\h{32}\z/)
    end

    it "differs between two different products" do
      other = create(:product)
      expect(described_class.current(product)).not_to eq(described_class.current(other))
    end
  end

  describe ".fresh?" do
    it "is true for the current token" do
      token = described_class.current(product)
      expect(described_class.fresh?(product:, token:)).to eq(true)
    end

    # A client that cannot say which snapshot it holds does not get to
    # delete. These three are exactly what a contract-unaware or broken
    # client would send.
    it "is false for a nil token" do
      expect(described_class.fresh?(product:, token: nil)).to eq(false)
    end

    it "is false for an empty-string token" do
      expect(described_class.fresh?(product:, token: "")).to eq(false)
    end

    it "is false for a junk token" do
      expect(described_class.fresh?(product:, token: "definitely-not-a-revision")).to eq(false)
    end

    it "is false for a token of the right shape but wrong value" do
      expect(described_class.fresh?(product:, token: "0" * 32)).to eq(false)
    end
  end

  describe "digest coverage" do
    # One example per collection: proves the digest actually covers all five
    # things the editor can delete, so a concurrent deletion anywhere in that
    # set invalidates an in-flight tab's token.
    it "changes the token when a rich content page is deleted" do
      page = create(:rich_content, entity: product)
      before = described_class.current(product)

      page.mark_deleted!

      expect(described_class.current(product)).not_to eq(before)
    end

    it "changes the token when a variant is deleted" do
      category = create(:variant_category, link: product)
      variant = create(:variant, variant_category: category)
      before = described_class.current(product)

      variant.mark_deleted!

      expect(described_class.current(product)).not_to eq(before)
    end

    it "changes the token when a file is deleted" do
      file = create(:product_file, link: product)
      before = described_class.current(product)

      file.mark_deleted!

      expect(described_class.current(product)).not_to eq(before)
    end

    it "changes the token when a public file is deleted" do
      public_file = create(:public_file, resource: product)
      before = described_class.current(product)

      public_file.mark_deleted!

      expect(described_class.current(product)).not_to eq(before)
    end

    it "changes the token when an integration is removed" do
      integration = create(:circle_integration)
      product.active_integrations << integration
      before = described_class.current(product)

      # Removal in the app soft-deletes the join row, which is what the
      # `active_integrations` (alive-scoped) association reads through.
      ProductIntegration.find_by!(integration:, product:).mark_deleted!

      expect(described_class.current(product.reload)).not_to eq(before)
    end

    it "changes the token when the product's own updated_at moves" do
      before = described_class.current(product)

      travel_to(1.minute.from_now) { product.touch }

      expect(described_class.current(product.reload)).not_to eq(before)
    end

    it "changes the token when VERSION is bumped, invalidating every outstanding token" do
      before = described_class.current(product)

      stub_const("Product::EditorRevision::VERSION", "v2-test")

      expect(described_class.current(product)).not_to eq(before)
      expect(described_class.fresh?(product:, token: before)).to eq(false)
    end
  end

  describe "ordering stability" do
    # The fingerprint plucks ids with an explicit .order(:id) because pluck
    # without an order can return rows in a different sequence between calls
    # (MySQL makes no ordering promise), which would make the digest differ
    # for identical state. We cannot force MySQL to reorder on demand, so
    # this asserts the observable property — many rows across several
    # collections, repeated calls, one token — which is what the explicit
    # ordering exists to guarantee.
    it "produces one token for identical multi-row state across many calls" do
      3.times { create(:rich_content, entity: product) }
      3.times { create(:product_file, link: product) }
      category = create(:variant_category, link: product)
      3.times { create(:variant, variant_category: category) }
      product.reload

      tokens = 10.times.map { described_class.current(product) }
      expect(tokens.uniq.size).to eq(1)
    end
  end
end
