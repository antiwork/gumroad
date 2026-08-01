# frozen_string_literal: true

require "spec_helper"

# `deleted_ids[:variants]` carries version ids only, never grouping ids
# (gumroad-private#1503).
#
# External ids are `ObfuscateIds.encrypt(primary_key)` with no table
# discriminator, and `base_variants`/`variant_categories` have independent
# auto-increment counters — so one id string can name both a version and a
# grouping. The deletion paths in Product::VariantCategoryUpdaterService resolve
# every id in `deleted_ids(:variants)` against VERSION external ids with no
# collision check. That is correct today only because no client can put a
# grouping id in that array; it is not a tie-break the server wins on merit.
#
# The first example pins what the collision actually costs, so nobody has to
# re-derive it. The rest are the tripwire: they fail the moment the editor grows
# a way to name a grouping in that collection.
describe "deleted_ids[:variants] kind invariant" do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }

  before { Feature.activate_user(Product::SaveContract::FEATURE_NAME, seller) }
  after { Feature.deactivate_user(Product::SaveContract::FEATURE_NAME, seller) }

  describe "the damage a grouping id would do if one ever reached the server" do
    it "deletes the colliding version, leaves the named grouping alive, and reports success" do
      category = create(:variant_category, link: product, title: "Groupings")
      version = create(:variant, variant_category: category, name: "V1")

      # Force the collision the id scheme permits: a grouping whose primary key
      # equals the version's, so both encrypt to the same string. Move BOTH rows
      # onto an id free in both tables rather than reusing whatever grouping
      # already sits at the version's id — when the two counters line up that row
      # is `category` itself, and the example then asserts the grouping under
      # test both survives and gets swept.
      collision_id = [BaseVariant.maximum(:id), VariantCategory.maximum(:id)].compact.max + 1
      BaseVariant.where(id: version.id).update_all(id: collision_id)
      version = Variant.find(collision_id)
      spare = create(:variant_category, link: product, title: "Collides")
      VariantCategory.where(id: spare.id).update_all(id: collision_id)
      colliding_category = VariantCategory.find(collision_id)

      expect(colliding_category.external_id).to eq(version.external_id)

      contract = Product::SaveContract.new(
        params: {
          editor_revision: Product::EditorRevision.current(product.reload),
          deletion_operations: { deleted_ids: { variants: [colliding_category.external_id] } },
        },
        product: product.reload
      )

      # The seller means "remove that grouping". The server has no way to know.
      Product::VariantCategoryUpdaterService.new(
        product: product,
        category_params: { id: category.external_id, name: "Groupings", options: nil },
        confirmed_removed_variant_ids: [colliding_category.external_id],
        contract: contract
      ).perform

      expect(version.reload.alive?).to eq(false), "the unrelated VERSION was deleted"
      expect(colliding_category.reload.alive?).to eq(true), "the grouping the seller named survived"
    end
  end

  describe "the client cannot construct that request" do
    javascript_root = Rails.root.join("app", "javascript")

    # Every file that APPENDS to confirmed_removed_variant_ids — the sole
    # upstream of deleted_ids[:variants]. Each of these four is a per-row
    # deletion modal for one kind of version row (versions, durations, tiers,
    # suggested amounts); none of them can hold a grouping.
    permitted_producers = %w[
      components/ProductEdit/ProductTab/VersionsEditor.tsx
      components/ProductEdit/ProductTab/DurationsEditor.tsx
      components/ProductEdit/ProductTab/TiersEditor.tsx
      components/ProductEdit/ProductTab/SuggestedAmountsEditor.tsx
    ]

    it "has no producer of confirmed_removed_variant_ids outside the version-row editors" do
      producers = Dir.glob(javascript_root.join("**", "*.{ts,tsx}")).filter_map do |path|
        next if path.end_with?(".test.ts", ".test.tsx")

        next unless File.read(path).match?(/product\.confirmed_removed_variant_ids\s*=/)

        Pathname.new(path).relative_path_from(javascript_root).to_s
      end

      expect(producers.sort).to eq(permitted_producers.sort),
                                "A new writer of confirmed_removed_variant_ids appeared. If it can name a " \
                                "VariantCategory (grouping), it will delete a colliding VERSION instead — see " \
                                "gumroad-private#1503. Give grouping deletion its own collection."
    end

    it "gives deleted_ids.variants exactly one producer, fed only by confirmed_removed_variant_ids" do
      contract_source = File.read(javascript_root.join("data", "product_save_contract.ts"))

      assignments = contract_source.scan(/deletedIds\.variants\s*=\s*(.+)/).flatten
      expect(assignments.size).to eq(1)
      expect(assignments.first).to include("removedVariants")
      expect(contract_source).to include("const removedVariants = product.confirmed_removed_variant_ids ?? [];")
    end

    it "exposes no grouping as a deletable object in the product editor" do
      editor_sources = Dir.glob(javascript_root.join("components", "ProductEdit", "**", "*.{ts,tsx}")) +
                       [javascript_root.join("data", "product_edit.ts").to_s]

      naming_groupings = editor_sources.filter_map do |path|
        next unless File.read(path).match?(/variant_categor|variantCategor/i)

        Pathname.new(path).relative_path_from(javascript_root).to_s
      end

      expect(naming_groupings).to be_empty,
                                  "The editor now references variant categories. A grouping still cannot be " \
                                  "named in deleted_ids[:variants] — see gumroad-private#1503."
    end
  end
end
