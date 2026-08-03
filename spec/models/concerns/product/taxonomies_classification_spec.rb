# frozen_string_literal: true

require "spec_helper"

describe "Discover taxonomy attribute classification on product changes" do
  let(:fonts_taxonomy) { Taxonomy.find_or_create_by!(slug: "fonts", parent: Taxonomy.find_or_create_by!(slug: "design")) }

  before do
    TaxonomyAttribute.where(taxonomy: fonts_taxonomy).delete_all
    TaxonomyAttribute.create!(taxonomy: fonts_taxonomy, name: "format", label: "Format", value_type: "enum", values: %w[OTF TTF WOFF2], position: 0)
  end

  it "classifies when a product's taxonomy changes" do
    product = create(:product)
    create(:product_file, link: product, url: "#{S3_BASE_URL}specs/font.otf")

    product.update!(taxonomy: fonts_taxonomy)

    expect(product.reload.inferred_taxonomy_attribute_values).to eq("format" => "OTF")
  end

  it "reclassifies when a product file is added to a product already in a classified taxonomy" do
    product = create(:product, taxonomy: fonts_taxonomy)
    expect(product.reload.inferred_taxonomy_attribute_values).to eq({})

    create(:product_file, link: product, url: "#{S3_BASE_URL}specs/font.otf")

    expect(product.reload.inferred_taxonomy_attribute_values).to eq("format" => "OTF")
  end

  it "reclassifies when the only signal-bearing file is deleted" do
    product = create(:product, taxonomy: fonts_taxonomy)
    file = create(:product_file, link: product, url: "#{S3_BASE_URL}specs/font.otf")
    expect(product.reload.inferred_taxonomy_attribute_values).to eq("format" => "OTF")

    file.mark_deleted!

    expect(product.reload.inferred_taxonomy_attribute_values).to eq({})
  end

  it "does not touch products outside a classified taxonomy" do
    other = Taxonomy.find_or_create_by!(slug: "some-other-category")
    product = create(:product, taxonomy: other)
    create(:product_file, link: product, url: "#{S3_BASE_URL}specs/font.otf")

    expect(product.reload.inferred_taxonomy_attribute_values).to eq({})
  end
end
