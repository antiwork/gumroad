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

    it "builds a media card from upload_media with the hosted url as the copy target" do
      response = { "success" => true, "media" => { "id" => "abc123", "name" => "My logo", "extension" => "PNG", "file_size" => 49_152, "file_group" => "image", "url" => "https://public-files.gumroad.com/abc.png" } }

      card = described_class.from_response(catalog.find("upload_media"), response).first

      expect(card[:type]).to eq("media")
      expect(card[:title]).to eq("My logo")
      expect(card[:subtitle]).to eq("Image")
      expect(card[:url]).to eq("https://public-files.gumroad.com/abc.png")
      expect(card[:copy]).to eq("https://public-files.gumroad.com/abc.png")
      expect(card[:fields]).to include({ label: "Type", value: "PNG" })
    end

    it "builds media cards from list_media" do
      response = { "success" => true, "media" => [{ "id" => "m1", "name" => "Track" }, { "id" => "m2", "name" => "Banner" }] }

      cards = described_class.from_response(catalog.find("list_media"), response)

      expect(cards.map { |c| c[:title] }).to eq(%w[Track Banner])
    end

    # A looked-up help article gets a card so the creator gets a link to the documentation the
    # answer came from, rather than only the agent's paraphrase of it.
    it "builds a help article card with a link to the live article" do
      response = {
        "success" => true,
        "help_article" => {
          "slug" => "124-your-gumroad-profile-page",
          "title" => "Your Gumroad profile page",
          "description" => "How your storefront works.",
          "category" => "Start selling",
          "url" => "https://gumroad.com/help/article/124-your-gumroad-profile-page",
          "content" => "Long plain text...",
        },
      }

      card = described_class.from_response(catalog.find("get_help_article"), response).first

      expect(card[:type]).to eq("help_article")
      expect(card[:title]).to eq("Your Gumroad profile page")
      expect(card[:subtitle]).to eq("Start selling")
      expect(card[:url]).to eq("https://gumroad.com/help/article/124-your-gumroad-profile-page")
      expect(card[:fields]).to include({ label: "About", value: "How your storefront works." })
    end

    # The search results are a list the model reads to pick an article; rendering 100+ doc cards
    # under the reply would bury the answer, so only the article it actually reads gets a card.
    it "does not build cards for a help article search" do
      response = { "success" => true, "help_articles" => [{ "slug" => "a", "title" => "A" }] }

      expect(described_class.from_response(catalog.find("search_help_articles"), response)).to eq([])
    end
  end
end
