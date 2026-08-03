# frozen_string_literal: true

require "spec_helper"

describe Discover::FontsAttributeClassifier do
  let(:fonts_taxonomy) { Taxonomy.find_or_create_by!(slug: "fonts", parent: Taxonomy.find_or_create_by!(slug: "design")) }
  let(:product) { create(:product, taxonomy: fonts_taxonomy) }

  before do
    TaxonomyAttribute.where(taxonomy: fonts_taxonomy).delete_all
    TaxonomyAttribute.create!(taxonomy: fonts_taxonomy, name: "format", label: "Format", value_type: "enum", values: %w[OTF TTF WOFF2], position: 0)
    TaxonomyAttribute.create!(taxonomy: fonts_taxonomy, name: "variable_font", label: "Variable font", value_type: "boolean", values: [], position: 1)
  end

  describe "#inferred_values" do
    it "infers the format from a single font file's extension" do
      create(:product_file, link: product, url: "#{S3_BASE_URL}specs/font.otf")

      expect(described_class.new(product).inferred_values).to eq("format" => "OTF")
    end

    it "leaves format unset when the product has more than one font extension, rather than guessing" do
      create(:product_file, link: product, url: "#{S3_BASE_URL}specs/font.otf")
      create(:product_file, link: product, url: "#{S3_BASE_URL}specs/font.ttf")

      expect(described_class.new(product).inferred_values).to eq({})
    end

    it "leaves format unset when there is no font-extension signal at all" do
      create(:product_file, link: product, url: "#{S3_BASE_URL}specs/readme.pdf")

      expect(described_class.new(product).inferred_values).to eq({})
    end

    it "detects a variable font from the file name regardless of the format signal" do
      create(:product_file, link: product, url: "#{S3_BASE_URL}specs/font.otf")
      create(:product_file, link: product, url: "#{S3_BASE_URL}specs/font-Variable.ttf")

      # Two extensions still block `format`, but `variable_font` has its own independent signal.
      expect(described_class.new(product).inferred_values).to eq("variable_font" => true)
    end

    it "ignores deleted files" do
      file = create(:product_file, link: product, url: "#{S3_BASE_URL}specs/font.otf")
      file.mark_deleted!

      expect(described_class.new(product).inferred_values).to eq({})
    end
  end

  describe "#classify!" do
    it "writes to inferred_taxonomy_attribute_values, not the seller-entered key" do
      create(:product_file, link: product, url: "#{S3_BASE_URL}specs/font.otf")

      described_class.new(product.reload).classify!

      expect(product.reload.inferred_taxonomy_attribute_values).to eq("format" => "OTF")
      expect(product.seller_taxonomy_attribute_values).to eq({})
    end

    it "never overwrites a seller's explicit answer even when it disagrees with the file" do
      create(:product_file, link: product, url: "#{S3_BASE_URL}specs/font.otf")
      product.save_taxonomy_attribute_values("format" => "TTF")

      described_class.new(product).classify!

      expect(product.reload.seller_taxonomy_attribute_values).to eq("format" => "TTF")
      expect(product.taxonomy_attribute_values).to eq("format" => "TTF")
    end
  end
end
