# frozen_string_literal: true

require "spec_helper"

describe TaxonomyAttributeDefinitions do
  describe ".taxonomy_for" do
    it "resolves a nested slug path" do
      design = Taxonomy.find_or_create_by!(slug: "design")
      fonts = Taxonomy.find_or_create_by!(slug: "fonts", parent: design)

      expect(described_class.taxonomy_for("design/fonts")).to eq(fonts)
    end

    it "does not match a same-named leaf under a different parent" do
      design = Taxonomy.find_or_create_by!(slug: "design")
      Taxonomy.find_or_create_by!(slug: "fonts", parent: design)
      other = Taxonomy.find_or_create_by!(slug: "three-d")
      decoy = Taxonomy.find_or_create_by!(slug: "fonts", parent: other)

      expect(described_class.taxonomy_for("design/fonts")).not_to eq(decoy)
    end

    it "returns nil when any segment is missing" do
      expect(described_class.taxonomy_for("design/nonexistent-category")).to be_nil
    end
  end

  describe "DEFINITIONS" do
    it "only uses value types the model accepts" do
      types = described_class::DEFINITIONS.values.flatten.map { _1[:value_type] }.uniq

      expect(types - TaxonomyAttribute::VALUE_TYPES).to be_empty
    end

    it "uses names the model's format validation accepts, unique within a category" do
      described_class::DEFINITIONS.each do |slug_path, definitions|
        names = definitions.map { _1[:name] }

        expect(names.uniq.size).to eq(names.size), "duplicate attribute name in #{slug_path}"
        names.each { expect(_1).to match(/\A[a-z0-9_]+\z/) }
      end
    end
  end

  describe ".each_taxonomy_with_definitions" do
    it "skips configured paths whose taxonomy does not exist" do
      Taxonomy.where(slug: "fonts").destroy_all

      expect(described_class.each_taxonomy_with_definitions.to_a).to be_empty
    end
  end
end
