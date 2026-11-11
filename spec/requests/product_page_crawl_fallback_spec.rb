# frozen_string_literal: true

require "spec_helper"

describe "product page crawl fallback", type: :request do
  let(:seller) { create(:user, name: "Fallback Seller") }

  def noscript_fallback
    Nokogiri::HTML.parse(response.body).at_css("noscript article")
  end

  def get_product(product, params = {})
    get "http://#{seller.subdomain}/l/#{product.unique_permalink}", params:
  end

  context "when the product is public" do
    let(:product) do
      create(
        :product,
        user: seller,
        name: "Crawlable Product",
        price_cents: 1_500,
        description: "<p>First paragraph</p><p>Second paragraph</p>"
      )
    end

    it "serves the product name, seller, price and description inside noscript" do
      get_product(product)

      expect(response).to have_http_status(:ok)

      fallback = noscript_fallback
      expect(fallback).to be_present
      expect(fallback.at_css("h1").text.strip).to eq("Crawlable Product")

      text = fallback.text
      expect(text).to include("by Fallback Seller")
      expect(text).to include("$15")
      expect(text).to include("First paragraph")
      expect(text).to include("Second paragraph")
    end

    it "keeps each block of the description as its own paragraph" do
      product.update!(description: "<h2>What you get</h2><p>First paragraph</p><ul><li>Item A</li><li>Item B</li></ul><p>Line one<br>Line two</p>")

      get_product(product)

      paragraphs = noscript_fallback.css("p").map { _1.text.strip }
      expect(paragraphs).to include("What you get", "First paragraph", "Item A", "Item B", "Line one\nLine two")
    end

    it "quotes a recurring product with its recurrence, not the bare amount" do
      membership = create(
        :membership_product,
        user: seller,
        name: "Recurring Product",
        price_cents: 1_000
      )

      get_product(membership)

      expect(noscript_fallback.css("p").map { _1.text.strip }).to include("$10 a month")
    end

    it "quotes the price a default discount leaves, as the product page does" do
      offer_code = seller.offer_codes.create!(code: "half", amount_percentage: 50, products: [product])
      product.update!(default_offer_code: offer_code)

      get_product(product)

      expect(noscript_fallback.text).to include("$7.50")
      expect(noscript_fallback.text).not_to include("$15")
    end

    it "leaves out the price instead of failing for a product with no stored currency" do
      product.update_column(:price_currency_type, nil)

      get_product(product)

      expect(response).to have_http_status(:ok)
      expect(noscript_fallback.at_css("h1").text).to eq("Crawlable Product")
      expect(noscript_fallback.css("p").map { _1.text.strip }).to eq(["by Fallback Seller", "First paragraph", "Second paragraph"])
    end

    it "cannot be made to close the noscript element from the description" do
      product = create(
        :product,
        user: seller,
        name: "Injection Product",
        description: "<p>before</p></NOSCRIPT><img src=x onerror=\"alert(1)\"><p>after</p>"
      )

      get_product(product)

      expect(response.body.scan(%r{</noscript}i).size).to eq(1)
      expect(response.body).not_to include("<img src=x")
    end

    it "keeps an escaped closing tag in the description as text" do
      product.update!(description: "<p>&lt;/noscript&gt;&lt;img src=x onerror=alert(1)&gt;</p>")

      get_product(product)

      expect(response.body.scan(%r{</noscript}i).size).to eq(1)
      expect(noscript_fallback.text).to include("</noscript><img src=x onerror=alert(1)>")
    end

    it "escapes the product and seller names" do
      seller.update!(name: "</noscript><script>alert(1)</script>")
      product.update!(name: "</NOSCRIPT ><b>Bold</b>")

      get_product(product)

      expect(response.body.scan(%r{</noscript}i).size).to eq(1)
      expect(noscript_fallback.at_css("h1").text).to eq("</NOSCRIPT ><b>Bold</b>")
      expect(noscript_fallback.text).to include("by </noscript><script>alert(1)</script>")
    end

    it "leaves out description text the product page does not show" do
      product.update!(description: "<p>Shown copy</p><table><tr><td>Hidden cell</td></tr></table>")

      get_product(product)

      expect(noscript_fallback.text).to include("Shown copy")
      expect(noscript_fallback.text).not_to include("Hidden cell")
    end

    it "does not truncate a long description" do
      long_description = Array.new(2_000) { |i| "word#{i}" }.join(" ")
      product = create(:product, user: seller, description: "<p>#{long_description}</p>")

      get_product(product)

      expect(noscript_fallback.text).to include("word0")
      expect(noscript_fallback.text).to include("word1999")
    end
  end

  context "when the page is not the public product page" do
    let(:product) { create(:product, user: seller) }

    it "omits the fallback for an embedded frame, an overlay and the Discover layout" do
      [{ embed: true }, { overlay: true }, { layout: Product::Layout::DISCOVER }].each do |params|
        get_product(product, params)

        expect(response).to have_http_status(:ok)
        expect(noscript_fallback).to be_nil
      end
    end

    it "omits the fallback for a draft or unpublished product" do
      [create(:product, user: seller, draft: true), create(:product, user: seller, purchase_disabled_at: Time.current)].each do |hidden|
        get_product(hidden)

        expect(response).to have_http_status(:ok)
        expect(noscript_fallback).to be_nil
      end
    end
  end
end
