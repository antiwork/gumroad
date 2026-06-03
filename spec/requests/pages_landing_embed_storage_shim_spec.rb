# frozen_string_literal: true

require "spec_helper"

# The custom landing page renders on an opaque origin (sandbox allow-scripts,
# no allow-same-origin), where reading localStorage / sessionStorage /
# document.cookie throws SecurityError. The embed document injects a
# compatibility shim BEFORE the seller's markup so a storage-touching seller
# script (e.g. a theme toggle) runs instead of throwing and blanking the page.
describe "GET /l/:id/landing/embed storage shim", type: :request do
  let(:seller) { create(:user, username: "shimseller") }
  let(:product) do
    create(
      :product,
      user: seller,
      custom_html: %(<main><div id="creator-marker">SELLER CONTENT</div><button data-gumroad-action="buy">Buy</button></main>)
    )
  end

  before { Feature.activate_user(:custom_html_pages, seller) }

  def get_embed
    get "/l/#{product.unique_permalink}/landing/embed", headers: { "HOST" => VALID_REQUEST_HOSTS.first }
  end

  it "injects the sandbox compatibility shim into the embed document" do
    get_embed

    expect(response).to be_successful
    expect(response.body).to include("data-gumroad-sandbox-shim")
  end

  it "provides in-memory stand-ins for localStorage, sessionStorage and document.cookie" do
    get_embed

    body = response.body
    expect(body).to include("localStorage")
    expect(body).to include("sessionStorage")
    expect(body).to include('Object.defineProperty(document, "cookie"')
  end

  it "loads the shim in the head, before <body>, so it runs first without being the body's first child" do
    get_embed

    body = response.body
    shim_index = body.index("data-gumroad-sandbox-shim")
    body_tag_index = body.index("<body")
    seller_index = body.index("creator-marker")

    expect(shim_index).to be_present
    expect(body_tag_index).to be_present
    expect(seller_index).to be_present
    expect(shim_index).to be < body_tag_index
    expect(shim_index).to be < seller_index
  end
end
