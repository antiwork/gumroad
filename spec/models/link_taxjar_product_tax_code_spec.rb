# frozen_string_literal: true

require "spec_helper"

describe Link, "#taxjar_product_tax_code" do
  # The spec database is seeded with the whole Discover tree, so look the existing nodes up
  # rather than creating them — `create(:taxonomy, slug: ...)` raises "Slug has already been
  # taken", and exercising the seeded tree is also what production looks like.
  let(:software_and_plugins) { Taxonomy.find_by!(slug: "software-and-plugins") }
  let(:wordpress) { Taxonomy.find_by!(slug: "wordpress") }

  it "keeps digital on 31000 when Discover is untagged" do
    product = create(:product, native_type: "digital")

    expect(product.taxjar_product_tax_code).to eq("31000")
  end

  it "maps digital tagged software-and-plugins to 30070" do
    product = create(:product, native_type: "digital", taxonomy: software_and_plugins)

    expect(product.taxjar_product_tax_code).to eq("30070")
  end

  it "maps digital tagged as a software-and-plugins child to 30070" do
    product = create(:product, native_type: "digital", taxonomy: wordpress)

    expect(product.taxjar_product_tax_code).to eq("30070")
  end

  it "does not remap membership tagged software-and-plugins" do
    product = create(:product, native_type: "membership", taxonomy: software_and_plugins)

    expect(product.taxjar_product_tax_code).to eq("55111516A0310")
  end

  it "does not remap an unrelated Discover taxonomy" do
    product = create(:product, native_type: "digital", taxonomy: Taxonomy.find_by!(slug: "design"))

    expect(product.taxjar_product_tax_code).to eq("31000")
  end
end
