# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("db/migrate/20261216150000_add_music_theory_and_composition_taxonomies").to_s

describe AddMusicTheoryAndCompositionTaxonomies do
  subject(:migration) { described_class.new }

  let(:parent) { Taxonomy.find_by_path([described_class::PARENT_SLUG]) }

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
    it "creates Music Theory and Composition under Music & Sound Design" do
      migration.up

      expect(Taxonomy.where(parent:).pluck(:slug)).to include(*described_class::SLUGS)
      described_class::SLUGS.each do |slug|
        expect(Taxonomy.find_by_path([described_class::PARENT_SLUG, slug])).to be_present
      end
    end

    it "registers the rows with closure_tree so the nav can resolve their root" do
      migration.up

      taxonomy = Taxonomy.find_by_path(%w[music-and-sound-design music-theory])

      expect(taxonomy.self_and_ancestors.pluck(:slug)).to eq(%w[music-theory music-and-sound-design])
    end

    it "leaves the existing subcategories alone" do
      expect { migration.up }.not_to change { Taxonomy.where(parent:).where.not(slug: described_class::SLUGS).pluck(:id).sort }
    end

    it "is idempotent" do
      migration.up

      expect { migration.up }.not_to change(Taxonomy, :count)
    end

    it "busts the nav cache so the categories are visible before the hour is out" do
      Rails.cache.write("taxonomies_for_nav", [{ slug: "stale" }])

      migration.up

      expect(Rails.cache.read("taxonomies_for_nav")).to be_nil
    end

    it "raises in production when Music & Sound Design is missing" do
      allow(Taxonomy).to receive(:find_by_path).with([described_class::PARENT_SLUG]).and_return(nil)
      allow(Rails.env).to receive(:production?).and_return(true)

      expect { migration.up }.to raise_error(ActiveRecord::RecordNotFound, /music-and-sound-design/)
    end

    it "skips quietly outside production when Music & Sound Design is missing" do
      allow(Taxonomy).to receive(:find_by_path).with([described_class::PARENT_SLUG]).and_return(nil)

      expect { migration.up }.not_to raise_error
    end
  end

  describe "#down" do
    it "removes the rows it created" do
      migration.up

      migration.down

      described_class::SLUGS.each do |slug|
        expect(Taxonomy.find_by_path([described_class::PARENT_SLUG, slug])).to be_nil
      end
    end

    it "keeps a row a seller has already categorised a product under" do
      migration.up
      in_use = Taxonomy.find_by_path(%w[music-and-sound-design music-theory])
      create(:product, taxonomy: in_use)

      migration.down

      expect(in_use.reload).to be_present
      expect(Taxonomy.find_by_path(%w[music-and-sound-design composition])).to be_nil
    end

    it "busts the nav cache" do
      migration.up
      Rails.cache.write("taxonomies_for_nav", [{ slug: "stale" }])

      migration.down

      expect(Rails.cache.read("taxonomies_for_nav")).to be_nil
    end

    it "does nothing when the rows are already absent" do
      expect { migration.down }.not_to raise_error
    end
  end
end
