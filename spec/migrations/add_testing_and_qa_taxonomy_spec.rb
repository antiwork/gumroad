# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("db/migrate/20261226000007_add_testing_and_qa_taxonomy").to_s

describe AddTestingAndQaTaxonomy do
  subject(:migration) { described_class.new }

  # The spec database is already seeded with the whole tree, so exercising the create path means
  # removing the subtree first — which is also what production looks like before the migration.
  def remove_testing_and_qa_subtree
    category = Taxonomy.find_by_path([described_class::PARENT_SLUG, described_class::CATEGORY_SLUG])
    return if category.nil?

    Taxonomy.where(parent: category).each(&:destroy!)
    category.destroy!
  end

  before do
    migration.verbose = false
    remove_testing_and_qa_subtree
  end

  describe "#up" do
    it "creates the category and its subcategories under Software Development" do
      migration.up

      category = Taxonomy.find_by_path(%w[software-development testing-and-qa])
      expect(category).to be_present
      expect(Taxonomy.where(parent: category).pluck(:slug)).to match_array(described_class::SUBCATEGORY_SLUGS)
    end

    it "registers the rows with closure_tree so the nav can resolve their root" do
      migration.up

      subcategory = Taxonomy.find_by_path(%w[software-development testing-and-qa test-automation])

      # Inserting straight into the table leaves taxonomy_hierarchies empty, which find_by_path
      # survives (it walks parent_id) but self_and_ancestors does not — and that is what
      # taxonomies_for_nav calls to group a recommended product under its root.
      expect(subcategory.self_and_ancestors.pluck(:slug)).to eq(
        %w[test-automation testing-and-qa software-development]
      )
    end

    it "makes the new category reachable by its Discover path" do
      migration.up

      expect(Taxonomy.find_by_path(%w[software-development testing-and-qa test-automation])).to be_present
    end

    it "leaves the existing subcategories alone" do
      migration.up

      expect(Taxonomy.find_by_path(%w[software-development cybersecurity])).to be_present
      expect(Taxonomy.find_by_path(%w[software-development web-development web-templates])).to be_present
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

    it "raises in production when Software Development is missing" do
      allow(Taxonomy).to receive(:find_by_path).with([described_class::PARENT_SLUG]).and_return(nil)
      allow(Rails.env).to receive(:production?).and_return(true)

      expect { migration.up }.to raise_error(ActiveRecord::RecordNotFound, /software-development/)
    end

    it "skips quietly outside production when Software Development is missing, creating nothing" do
      allow(Taxonomy).to receive(:find_by_path).with([described_class::PARENT_SLUG]).and_return(nil)
      Rails.cache.write("taxonomies_for_nav", [{ slug: "stale" }])

      # Without the early return, find_or_create_by! with a nil parent would add a root-level
      # testing-and-qa.
      expect { migration.up }.not_to change(Taxonomy, :count)
      expect(Rails.cache.read("taxonomies_for_nav")).to eq([{ slug: "stale" }])
    end
  end

  describe "#down" do
    it "removes the subtree it created" do
      migration.up

      migration.down

      expect(Taxonomy.find_by_path([described_class::PARENT_SLUG, described_class::CATEGORY_SLUG])).to be_nil
    end

    it "keeps a subcategory a seller has already categorised a product under" do
      migration.up
      in_use = Taxonomy.find_by_path(%w[software-development testing-and-qa test-automation])
      create(:product, taxonomy: in_use)

      migration.down

      expect(in_use.reload).to be_present
      expect(Taxonomy.find_by_path(%w[software-development testing-and-qa manual-testing])).to be_nil
    end

    it "keeps the parent category when a child is kept, so the child is never orphaned" do
      migration.up
      in_use = Taxonomy.find_by_path(%w[software-development testing-and-qa test-automation])
      create(:product, taxonomy: in_use)

      migration.down

      category = Taxonomy.find_by_path([described_class::PARENT_SLUG, described_class::CATEGORY_SLUG])
      expect(category).to be_present
      expect(in_use.reload.parent).to eq(category)
      expect(in_use.self_and_ancestors.pluck(:slug)).to eq(
        %w[test-automation testing-and-qa software-development]
      )
    end

    it "keeps the category when a product points at the category itself" do
      migration.up
      category = Taxonomy.find_by_path([described_class::PARENT_SLUG, described_class::CATEGORY_SLUG])
      create(:product, taxonomy: category)

      migration.down

      expect(category.reload).to be_present
      expect(Taxonomy.where(parent: category)).to be_empty
    end

    it "does nothing when the category is already absent" do
      expect { migration.down }.not_to raise_error
    end
  end
end
