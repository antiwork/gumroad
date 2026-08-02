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
    # The Inertia product prop still carries the canonical subdomain long_url; only the
    # head tags search engines read are re-pointed.
    expect(response.body).not_to include(%(href="#{product.long_url}"))
  end

  it "keeps the subdomain canonical when the request is not on a custom domain" do
    get product.long_url

    expect(response).to be_successful
    expect(response.body).to include(%(href="#{product.long_url}"))
    expect(response.body).not_to include("seller.example.com")
  end

  # /l/:permalink resolves globally, so another seller's product is reachable over this domain.
  # Canonicalizing it here would hand this domain Google's copy of someone else's page.
  it "keeps the subdomain canonical for a product whose seller does not own this domain" do
    other_product = create(:product, user: create(:user, username: "otherseller"), name: "Someone Else's")

    get "http://seller.example.com/l/#{other_product.unique_permalink}"

    expect(response).to be_successful
    expect(response.body).to include(%(href="#{other_product.long_url}"))
    expect(response.body).not_to include(%(href="http://seller.example.com/l/))
  end

  context "with a product that emits JSON-LD" do
    let(:product) { create(:product, user: seller, name: "Canonical Ebook", native_type: Link::NATIVE_TYPE_EBOOK) }

    it "uses the custom domain for the structured-data urls too" do
      custom_domain_url = "http://seller.example.com"

      structured_data = product.structured_data(host: custom_domain_url)
      expect(structured_data["url"]).to eq("#{custom_domain_url}/l/#{product.unique_permalink}")
      expect(structured_data["offers"]["url"]).to eq("#{custom_domain_url}/l/#{product.unique_permalink}")

      # nil host keeps the pre-existing subdomain behaviour for gumroad.com requests.
      expect(product.structured_data["url"]).to eq(product.long_url)
    end
  end
end
