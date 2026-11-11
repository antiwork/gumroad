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

    it "keeps block boundaries apart instead of running the words together" do
      get_product(product)

      expect(noscript_fallback.text).not_to include("paragraphSecond")
    end

    it "quotes a recurring product with its recurrence, not the bare amount" do
      membership = create(
        :membership_product,
        user: seller,
        name: "Monthly Product",
        price_cents: 1_000
      )

      get_product(membership)

      fallback = noscript_fallback
      expect(fallback).to be_present
      expect(fallback.text).to include("$10")
      expect(fallback.text.downcase).to include("month")
    end

    it "quotes the price a default discount leaves, as the product page does" do
      offer_code = seller.offer_codes.create!(code: "half", amount_percentage: 50, products: [product])
      product.update!(default_offer_code: offer_code)

      get_product(product)

      expect(noscript_fallback.text).to include("$7.50")
      expect(noscript_fallback.text).not_to include("$15")
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

    it "omits the fallback for an embedded frame" do
      get_product(product, { embed: true })

      expect(Nokogiri::HTML.parse(response.body).css("noscript article")).to be_empty
    end

    it "omits the fallback for an overlay" do
      get_product(product, { overlay: true })

      expect(Nokogiri::HTML.parse(response.body).css("noscript article")).to be_empty
    end

    it "omits the fallback for an unpublished product" do
      draft = create(:product, user: seller, draft: true)

      get_product(draft)

      expect(Nokogiri::HTML.parse(response.body).css("noscript article")).to be_empty
    end
  end
end
