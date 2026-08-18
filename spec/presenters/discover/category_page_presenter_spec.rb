# frozen_string_literal: true

require "spec_helper"

describe Discover::CategoryPagePresenter do
  let(:discover_host) { UrlService.discover_domain_with_protocol }
  let(:taxonomy) { Taxonomy.find_by_path(["software-development", "programming"]) }
  let(:search_results) do
    {
      total: 1234,
      products: [
        { name: "Learn Ruby", url: "#{discover_host}/l/learn-ruby", price_cents: 1999, currency_code: "usd" },
        { name: "Free Course", url: "#{discover_host}/l/free-course", price_cents: 0, currency_code: "usd" },
      ]
    }
  end

  subject(:presenter) do
    described_class.new(taxonomy_path: "software-development/programming", taxonomy:, search_results:)
  end

  describe "#title" do
    it "uses the SEO template with human-readable labels" do
      expect(presenter.title).to eq("Software Development » Programming — digital products by independent creators | Gumroad")
    end
  end

  describe "#meta_description" do
    it "includes the leaf category label and result count" do
      expect(presenter.meta_description).to include("1,234 Programming products from independent creators on Gumroad")
    end
  end

  describe "#breadcrumb_list_json_ld" do
    it "builds a BreadcrumbList from Discover root through each ancestor" do
      data = presenter.breadcrumb_list_json_ld

      expect(data["@context"]).to eq("https://schema.org")
      expect(data["@type"]).to eq("BreadcrumbList")
      expect(data["itemListElement"]).to eq(
        [
          { "@type" => "ListItem", "position" => 1, "name" => "Discover", "item" => "#{discover_host}/discover" },
          { "@type" => "ListItem", "position" => 2, "name" => "Software Development", "item" => "#{discover_host}/software-development" },
          { "@type" => "ListItem", "position" => 3, "name" => "Programming", "item" => "#{discover_host}/software-development/programming" },
        ]
      )
    end
  end

  describe "#item_list_json_ld" do
    it "lists products with name, url, and offer price" do
      data = presenter.item_list_json_ld

      expect(data["@type"]).to eq("ItemList")
      expect(data["numberOfItems"]).to eq(1234)
      first_item = data["itemListElement"].first
      expect(first_item).to include("@type" => "ListItem", "position" => 1)
      expect(first_item["item"]).to eq(
        "@type" => "Product",
        "name" => "Learn Ruby",
        "url" => "#{discover_host}/l/learn-ruby",
        "offers" => { "@type" => "Offer", "price" => 19.99, "priceCurrency" => "USD" }
      )
    end

    it "returns nil when there are no products" do
      presenter = described_class.new(taxonomy_path: "software-development/programming", taxonomy:, search_results: { total: 0, products: [] })
      expect(presenter.item_list_json_ld).to be_nil
    end
  end

  describe "#subcategory_links" do
    it "links each child taxonomy under the current path" do
      links = presenter.subcategory_links

      expect(links).to include(label: "C#", href: "#{discover_host}/software-development/programming/c-sharp")
      expect(links.map { _1[:href] }).to all(start_with("#{discover_host}/software-development/programming/"))
    end
  end

  describe ".root_category_links" do
    it "links every top-level taxonomy" do
      links = described_class.root_category_links

      expect(links).to include(label: "3D", href: "#{discover_host}/3d")
      expect(links.size).to eq(Taxonomy.roots.count)
    end
  end
end
