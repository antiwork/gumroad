# frozen_string_literal: true

require "spec_helper"

describe "API v2 product custom HTML", type: :request do
  let(:seller) { create(:user) }
  let(:other_seller) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let(:other_product) { create(:product, user: other_seller) }
  let(:oauth_application) { create(:oauth_application, owner: create(:user)) }
  let(:access_token) { create("doorkeeper/access_token", application: oauth_application, resource_owner_id: seller.id, scopes: "edit_products") }

  def json
    JSON.parse(response.body)
  end

  it "sanitizes custom HTML before storing while allowing inline JavaScript" do
    html = <<~HTML
      <section onclick="openModal()">
        <script>window.ready = true;</script>
        <script src="https://evil.com/x.js"></script>
        <a href="javascript:alert(1)">Click</a>
      </section>
    HTML

    put "/api/v2/products/#{product.external_id}.json",
        params: { access_token: access_token.token, custom_html: html }

    expect(response).to have_http_status(:ok)
    stored_html = product.reload.custom_html
    expect(stored_html).to include(%(onclick="openModal()"))
    expect(stored_html).to include("<script>window.ready = true;</script>")
    expect(stored_html).not_to include("evil.com")
    expect(stored_html).not_to include("javascript:")
  end

  it "returns custom HTML and its public URL from GET" do
    product.update!(custom_html: "<section>Published HTML</section>")

    get "/api/v2/products/#{product.external_id}.json",
        params: { access_token: access_token.token }

    expect(response).to have_http_status(:ok)
    expect(json.dig("product", "custom_html")).to eq("<section>Published HTML</section>")
    expect(json.dig("product", "custom_html_url")).to include("/l/#{product.unique_permalink}")
  end

  it "clears custom HTML when passed nil" do
    product.update!(custom_html: "<section>Published HTML</section>")

    put "/api/v2/products/#{product.external_id}.json",
        params: { access_token: access_token.token, custom_html: nil }

    expect(response).to have_http_status(:ok)
    expect(product.reload.custom_html).to be_nil
  end

  it "returns 401 without a token" do
    put "/api/v2/products/#{product.external_id}.json",
        params: { custom_html: "<section>HTML</section>" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns 403 when updating another seller's product" do
    put "/api/v2/products/#{other_product.external_id}.json",
        params: { access_token: access_token.token, custom_html: "<section>HTML</section>" }
    expect(response).to have_http_status(:forbidden)
  end
end
