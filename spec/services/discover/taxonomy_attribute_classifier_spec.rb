# frozen_string_literal: true

require "spec_helper"

describe Discover::TaxonomyAttributeClassifier do
  let(:fonts_taxonomy) { Taxonomy.find_or_create_by!(slug: "fonts", parent: Taxonomy.find_or_create_by!(slug: "design")) }
  let(:other_taxonomy) { Taxonomy.find_or_create_by!(slug: "some-other-category") }

  before do
    TaxonomyAttribute.where(taxonomy: fonts_taxonomy).delete_all
    TaxonomyAttribute.create!(taxonomy: fonts_taxonomy, name: "format", label: "Format", value_type: "enum", values: %w[OTF TTF WOFF2], position: 0)
  end

  describe ".classify!" do
    it "delegates to the registered classifier for the product's taxonomy path" do
      product = create(:product, taxonomy: fonts_taxonomy)
      create(:product_file, link: product, url: "#{S3_BASE_URL}specs/font.otf")

      expect(described_class.classify!(product)).to eq(true)
      expect(product.reload.inferred_taxonomy_attribute_values).to eq("format" => "OTF")
    end

    it "is a no-op for a taxonomy with no registered classifier" do
      product = create(:product, taxonomy: other_taxonomy)

      expect(described_class.classify!(product)).to eq(false)
    end

    it "is a no-op for a product with no taxonomy" do
      product = create(:product, taxonomy: nil)

      expect(described_class.classify!(product)).to eq(false)
    end

    it "clears a stale inferred value when the product moves to an unregistered taxonomy" do
      product = create(:product, taxonomy: fonts_taxonomy)
      create(:product_file, link: product, url: "#{S3_BASE_URL}specs/font.otf")
      described_class.classify!(product)
      expect(product.reload.inferred_taxonomy_attribute_values).to eq("format" => "OTF")

      product.update!(taxonomy: other_taxonomy)

      expect(product.reload.inferred_taxonomy_attribute_values).to eq({})
    end
  end

  describe ".inferred_values_for" do
    it "is a pure read that does not persist anything" do
      product = create(:product, taxonomy: fonts_taxonomy)
      create(:product_file, link: product, url: "#{S3_BASE_URL}specs/font.otf")

      expect { described_class.inferred_values_for(product) }
        .not_to change { product.reload.inferred_taxonomy_attribute_values }
    end
  end
end
