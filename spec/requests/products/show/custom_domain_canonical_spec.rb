# frozen_string_literal: true

require "spec_helper"

describe "Product page canonical URL on a custom domain", type: :request do
  let(:seller) { create(:user, username: "canonicalseller") }
  let(:product) { create(:product, user: seller, name: "Canonical Product") }
  let!(:custom_domain) { create(:custom_domain, :verified_with_certificate, user: seller, domain: "seller.example.com") }

  it "points the canonical and og:url at the seller's own domain" do
    get "http://seller.example.com/l/#{product.unique_permalink}"

    expect(response).to be_successful
    expect(response.body).to include(%(href="http://seller.example.com/l/#{product.unique_permalink}"))
    expect(response.body).to include(%(content="http://seller.example.com/l/#{product.unique_permalink}"))
    expect(response.body).not_to include("#{seller.username}.gumroad.com/l/#{product.unique_permalink}")
  end

  it "keeps the subdomain canonical when the request is not on a custom domain" do
    get product.long_url

    expect(response).to be_successful
    expect(response.body).to include("#{seller.username}.gumroad.com/l/#{product.unique_permalink}")
  end

  context "with a product that emits JSON-LD" do
    let(:product) { create(:product, user: seller, name: "Canonical Ebook", native_type: Link::NATIVE_TYPE_EBOOK) }

    it "uses the custom domain for the structured-data urls too" do
      get "http://seller.example.com/l/#{product.unique_permalink}"

      expect(response).to be_successful
      structured_data = product.structured_data(host: "http://seller.example.com")
      expect(structured_data["url"]).to eq("http://seller.example.com/l/#{product.unique_permalink}")
      expect(structured_data["offers"]["url"]).to eq("http://seller.example.com/l/#{product.unique_permalink}")
      expect(product.structured_data["url"]).to include("#{seller.username}.gumroad.com")
    end
  end
end
