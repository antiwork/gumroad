# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillTaxonomyAttributeClassification do
  let(:fonts_taxonomy) { Taxonomy.find_or_create_by!(slug: "fonts", parent: Taxonomy.find_or_create_by!(slug: "design")) }
  let(:other_taxonomy) { Taxonomy.find_or_create_by!(slug: "some-other-category") }

  before do
    TaxonomyAttribute.where(taxonomy: fonts_taxonomy).delete_all
    TaxonomyAttribute.create!(taxonomy: fonts_taxonomy, name: "format", label: "Format", value_type: "enum", values: %w[OTF TTF WOFF2], position: 0)
  end

  it "does not write anything on a dry run, but reports the distribution" do
    product = create(:product, taxonomy: fonts_taxonomy)
    create(:product_file, link: product, url: "#{S3_BASE_URL}specs/font.otf")

    result = nil
    expect { result = described_class.process(dry_run: true) }
      .not_to change { product.reload.inferred_taxonomy_attribute_values }
    expect(result[:stats][:would_infer]).to eq(1)
    expect(result[:distribution]["format"]).to eq("OTF" => 1)
  end

  it "writes inferred values on a real run" do
    product = create(:product, taxonomy: fonts_taxonomy)
    create(:product_file, link: product, url: "#{S3_BASE_URL}specs/font.otf")

    described_class.process(dry_run: false)

    expect(product.reload.inferred_taxonomy_attribute_values).to eq("format" => "OTF")
  end

  it "skips products with no classification signal" do
    create(:product, taxonomy: fonts_taxonomy)

    result = described_class.process(dry_run: false)

    expect(result[:stats][:skipped_no_signal]).to eq(1)
  end

  it "never touches a seller's explicit answer" do
    product = create(:product, taxonomy: fonts_taxonomy)
    create(:product_file, link: product, url: "#{S3_BASE_URL}specs/font.otf")
    product.save_taxonomy_attribute_values("format" => "TTF")

    described_class.process(dry_run: false)

    expect(product.reload.seller_taxonomy_attribute_values).to eq("format" => "TTF")
  end

  it "ignores products in a taxonomy with no registered classifier" do
    create(:product, taxonomy: other_taxonomy)

    result = described_class.process(dry_run: false)

    expect(result[:stats]).to eq(dry_run: false)
  end

  it "clears a stale inferred value on a real run when the classifier no longer returns one" do
    product = create(:product, taxonomy: fonts_taxonomy)
    product.update_column(:json_data, { "inferred_taxonomy_attribute_values" => { "format" => "OTF" } })

    result = described_class.process(dry_run: false)

    expect(product.reload.inferred_taxonomy_attribute_values).to eq({})
    expect(product.taxonomy_attribute_filter_tokens).to eq([])
    expect(result[:stats][:cleared]).to eq(1)
  end

  it "does not clear a stale inferred value on a dry run" do
    product = create(:product, taxonomy: fonts_taxonomy)
    product.update_column(:json_data, { "inferred_taxonomy_attribute_values" => { "format" => "OTF" } })

    described_class.process(dry_run: true)

    expect(product.reload.inferred_taxonomy_attribute_values).to eq("format" => "OTF")
  end
end
