# frozen_string_literal: true

require "spec_helper"

describe Link, "#taxjar_product_tax_code" do
  let(:software_development) { create(:taxonomy, slug: "software-development") }
  let(:software_and_plugins) { create(:taxonomy, slug: "software-and-plugins", parent: software_development) }
  let(:wordpress) { create(:taxonomy, slug: "wordpress", parent: software_and_plugins) }

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
    product = create(:product, native_type: "digital", taxonomy: create(:taxonomy, slug: "design"))

    expect(product.taxjar_product_tax_code).to eq("31000")
  end
end
