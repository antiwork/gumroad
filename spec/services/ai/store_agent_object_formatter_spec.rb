# frozen_string_literal: true

require "spec_helper"

describe Ai::StoreAgentObjectFormatter do
  let(:catalog) { Ai::StoreAgentApiCatalog }

  describe ".from_response" do
    it "returns [] for an error envelope" do
      objects = described_class.from_response(catalog.find("list_products"), { "success" => false, "message" => "nope" })
      expect(objects).to eq([])
    end

    it "returns [] for a non-hash response" do
      expect(described_class.from_response(catalog.find("list_products"), "oops")).to eq([])
    end

    it "builds product cards from list_products" do
      response = {
        "success" => true,
        "products" => [
          { "id" => "p1", "name" => "Cool Ebook", "formatted_price" => "$9.99", "published" => true, "sales_count" => 12, "short_url" => "https://x.gumroad.com/l/ebook" },
        ],
      }

      objects = described_class.from_response(catalog.find("list_products"), response)

      expect(objects.size).to eq(1)
      card = objects.first
      expect(card[:type]).to eq("product")
      expect(card[:title]).to eq("Cool Ebook")
      expect(card[:subtitle]).to eq("$9.99")
      expect(card[:url]).to eq("https://x.gumroad.com/l/ebook")
      expect(card[:copy]).to eq("https://x.gumroad.com/l/ebook")
      expect(card[:fields]).to include({ label: "Status", value: "Published" }, { label: "Sales", value: "12" })
    end

    it "builds a single product card from create_product / update_product" do
      response = { "success" => true, "product" => { "id" => "p2", "name" => "New Thing", "price" => 2500, "currency" => "usd", "published" => false } }

      card = described_class.from_response(catalog.find("create_product"), response).first

      expect(card[:type]).to eq("product")
      expect(card[:title]).to eq("New Thing")
      expect(card[:subtitle]).to eq("$25")
      expect(card[:fields]).to include({ label: "Status", value: "Unpublished" })
    end

    it "builds a discount card and copies the code" do
      response = { "success" => true, "offer_code" => { "id" => "o1", "name" => "LAUNCH25", "percent_off" => 25, "universal" => true, "times_used" => 3 } }

      card = described_class.from_response(catalog.find("create_offer_code"), response).first

      expect(card[:type]).to eq("discount")
      expect(card[:title]).to eq("LAUNCH25")
      expect(card[:subtitle]).to eq("25% off")
      expect(card[:copy]).to eq("LAUNCH25")
      expect(card[:fields]).to include({ label: "Applies to", value: "All products" }, { label: "Times used", value: "3" })
    end

    it "returns [] for an endpoint with no renderable shape" do
      expect(described_class.from_response(catalog.find("get_earnings"), { "success" => true, "earnings" => {} })).to eq([])
    end
  end
end
