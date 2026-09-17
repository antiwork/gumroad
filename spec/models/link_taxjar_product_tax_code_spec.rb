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

  # The sales-tax reports and uploads classify a whole month of purchases, so they resolve the
  # subtree once and pass it in. That path must not touch the taxonomy tables per link.
  it "classifies many links from one subtree lookup" do
    products = create_list(:product, 3, native_type: "digital", taxonomy: wordpress)
    subtree_ids = Taxonomy.software_and_plugins_subtree_ids

    taxonomy_queries = 0
    subscriber = ->(_name, _started, _finished, _id, payload) do
      taxonomy_queries += 1 if payload[:sql].match?(/taxonomy_hierarchies|taxonomies/)
    end

    codes = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      products.map { _1.taxjar_product_tax_code(software_and_plugins_taxonomy_ids: subtree_ids) }
    end

    expect(codes).to eq(["30070"] * 3)
    expect(taxonomy_queries).to eq(0)
  end
end
