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

    it "keeps the token when the product's own updated_at moves for an unrelated reason" do
      before = described_class.current(product)

      travel_to(1.minute.from_now) { product.touch }

      expect(described_class.current(product.reload)).to eq(before)
    end

    it "keeps the token when the seller edits the price" do
      before = described_class.current(product)
      updated_at_before = product.updated_at.to_fs(:usec)

      # `price_cents` is delegated to the default variant/price row, so writing
      # it does not dirty the product itself. Write `customizable_price` too:
      # it is a real Link column, so this genuinely moves the product's
      # updated_at and the assertion below can actually fail.
      travel_to(1.minute.from_now) do
        product.update!(price_cents: product.price_cents.to_i + 500, customizable_price: true)
      end

      expect(product.reload.updated_at.to_fs(:usec)).not_to eq(updated_at_before)
      expect(described_class.current(product)).to eq(before)
      expect(described_class.fresh?(product:, token: before)).to eq(true)
    end

    it "keeps the token when the seller edits tags, name or description" do
      before = described_class.current(product)

      product.tag!("a-brand-new-tag")
      product.update!(name: "A different name", description: "A different description")

      expect(described_class.current(product.reload)).to eq(before)
      expect(described_class.fresh?(product: product.reload, token: before)).to eq(true)
    end

    it "changes the token when the shared-content flag flips, because it changes which pages a save may delete" do
      product.update!(has_same_rich_content_for_all_variants: false)
      before = described_class.current(product.reload)

      product.update!(has_same_rich_content_for_all_variants: true)

      expect(described_class.current(product.reload)).not_to eq(before)
      expect(described_class.fresh?(product: product.reload, token: before)).to eq(false)
    end

    it "changes the token when is_tiered_membership flips, because it selects the variant deletion route" do
      # Link#valid_tier_version_structure rejects flipping this on a product
      # that has no Tier category, so start from a real membership and turn it
      # off — the digest only cares that the value moved.
      membership = create(:membership_product_with_preset_tiered_pricing)
      before = described_class.current(membership.reload)

      membership.update_attribute(:is_tiered_membership, false)

      expect(described_class.current(membership.reload)).not_to eq(before)
      expect(described_class.fresh?(product: membership.reload, token: before)).to eq(false)
    end

    it "raises rather than silently ignoring a deletion-relevant attribute that no longer exists" do
      stub_const("Product::EditorRevision::DELETION_RELEVANT_ATTRIBUTES", %w[no_such_attribute])

      expect { described_class.current(product) }
        .to raise_error(ArgumentError, /no such attribute/)
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
