# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("db/migrate/20261224000009_add_knitting_taxonomy").to_s

describe AddKnittingTaxonomy do
  subject(:migration) { described_class.new }

  # find_by_path walks from a root, so the parent is the full ancestor path, not its own slug.
  let(:parent) { Taxonomy.find_by_path(described_class::PARENT_PATH) }

  # The spec database is already seeded, so exercising the create path means removing the rows
  # first, which is also what production looks like before the migration.
  def remove_new_taxonomies
    Taxonomy.where(parent:, slug: described_class::SLUGS).each(&:destroy!)
  end

  before do
    migration.verbose = false
    remove_new_taxonomies
  end

  describe "#up" do
    it "creates Knitting under Crafts & DIY" do
      migration.up

      expect(Taxonomy.where(parent:).pluck(:slug)).to include(*described_class::SLUGS)
      described_class::SLUGS.each do |slug|
        expect(Taxonomy.find_by_path(described_class::PARENT_PATH + [slug])).to be_present
      end
    end

    it "registers the rows with closure_tree so the nav can resolve their root" do
      migration.up

      taxonomy = Taxonomy.find_by_path(%w[self-improvement crafts-and-dyi knitting])

      expect(taxonomy.self_and_ancestors.pluck(:slug)).to eq(%w[knitting crafts-and-dyi self-improvement])
    end

    it "leaves the existing subcategories alone" do
      expect { migration.up }.not_to change { Taxonomy.where(parent:).where.not(slug: described_class::SLUGS).pluck(:id).sort }
    end

    it "is idempotent" do
      migration.up

      expect { migration.up }.not_to change(Taxonomy, :count)
    end

    it "busts the nav cache so the category is visible before the hour is out" do
      Rails.cache.write("taxonomies_for_nav", [{ slug: "stale" }])

      migration.up

      expect(Rails.cache.read("taxonomies_for_nav")).to be_nil
    end

    it "raises in production when Crafts & DIY is missing" do
      allow(Taxonomy).to receive(:find_by_path).with(described_class::PARENT_PATH).and_return(nil)
      allow(Rails.env).to receive(:production?).and_return(true)

      expect { migration.up }.to raise_error(ActiveRecord::RecordNotFound, /crafts-and-dyi/)
    end

    it "skips quietly outside production when Crafts & DIY is missing, creating nothing" do
      allow(Taxonomy).to receive(:find_by_path).with(described_class::PARENT_PATH).and_return(nil)
      Rails.cache.write("taxonomies_for_nav", [{ slug: "stale" }])

      # Without the early return, find_or_create_by! with a nil parent would add a root-level Knitting.
      expect { migration.up }.not_to change(Taxonomy, :count)
      expect(Rails.cache.read("taxonomies_for_nav")).to eq([{ slug: "stale" }])
    end
  end

  describe "#down" do
    it "keeps the row, so a rollback cannot orphan a product saved under it" do
      migration.up
      in_use = Taxonomy.find_by_path(%w[self-improvement crafts-and-dyi knitting])
      product = create(:product, taxonomy: in_use)

      expect { migration.down }.not_to change(Taxonomy, :count)

      expect(product.reload.taxonomy).to eq(in_use)
    end
  end
end
