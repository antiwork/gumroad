# frozen_string_literal: true

require "spec_helper"

# The wishlist page applies the same 160-character cap to its description meta as the
# product page. The cut must land on a word boundary: this string is also the
# og:description, which link previews render verbatim, so a half-word tail is visible there.
describe "wishlist page meta description", type: :request do
  include Rails.application.routes.url_helpers

  let(:seller) { create(:user, name: "Wishlist User") }
  let(:long_description) { (1..40).map { |i| "word#{i}" }.join(" ") }
  let(:wishlist) { create(:wishlist, name: "My Wishlist", description: long_description, user: seller) }

  before do
    create(:wishlist_product, wishlist:, product: create(:product))
  end

  def rendered_meta_description
    response.body[%r{<meta name="description" content="([^"]*)"}, 1]
  end

  def rendered_og_description
    response.body[%r{<meta property="og:description" content="([^"]*)"}, 1]
  end

  it "caps the meta description and og:description at 160 characters, on a word boundary" do
    get wishlist_url(wishlist.external_id_numeric, host: seller.subdomain_with_protocol)

    expect(response).to have_http_status(:ok)

    meta_description = rendered_meta_description
    expect(meta_description).to be_present
    expect(meta_description.length).to be <= 160
    expect(meta_description).to end_with("...")
    expect(meta_description).to start_with("word1 word2")
    expect(rendered_og_description).to eq(meta_description)

    prefix = meta_description.delete_suffix("...")
    expect(long_description).to start_with(prefix)
    expect(long_description[prefix.length]).to eq(" ")
  end

  context "when the description already fits in a snippet" do
    let(:wishlist) { create(:wishlist, name: "My Wishlist", description: "A short wishlist description.", user: seller) }

    it "leaves the description untouched" do
      get wishlist_url(wishlist.external_id_numeric, host: seller.subdomain_with_protocol)

      expect(rendered_meta_description).to eq("A short wishlist description.")
      expect(rendered_og_description).to eq("A short wishlist description.")
    end
  end
end
