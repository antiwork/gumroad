# frozen_string_literal: true

require "spec_helper"

# Cheap wiring guard for the gumroad:background bridge. Its behavior is driven
# in a real browser in profile_custom_html_background_spec.rb, but that only
# covers the profile surface — three wrapper/embed pairs carry the fix, and
# dropping either half from any one of them is invisible to a browser spec that
# never visits it. These pin that both halves are present on every surface.
describe "Custom HTML background bridge wiring", type: :request do
  let(:seller) { create(:user, username: "bgwiring", name: "BG Wiring") }
  let(:page_html) { "<section><h1>Landing</h1></section>" }
  let(:host) { seller.subdomain_with_protocol }

  before { Feature.activate_user(:custom_html_pages, seller) }

  shared_examples "a surface carrying both halves of the bridge" do
    it "injects the reporter into the sandboxed embed" do
      get "#{host}#{embed_path}"

      expect(response).to be_successful
      expect(response.body).to include("data-gumroad-background-bridge")
      expect(response.body).to include("gumroad:background")
    end

    it "injects the listener into the trusted wrapper" do
      get "#{host}#{wrapper_path}"

      expect(response).to be_successful
      expect(response.body).to include("data-gumroad-background-wrapper")
      expect(response.body).to include("theme-color")
    end
  end

  context "the profile storefront" do
    before { seller.update!(custom_html: page_html) }

    let(:wrapper_path) { "/" }
    let(:embed_path) { "/landing/embed" }

    it_behaves_like "a surface carrying both halves of the bridge"
  end

  context "a slugged profile page" do
    before { create(:user_page, pageable: seller, slug: "about", title: "About", custom_html: page_html) }

    let(:wrapper_path) { "/about" }
    let(:embed_path) { "/about/landing/embed" }

    it_behaves_like "a surface carrying both halves of the bridge"
  end

  context "a product landing page" do
    let!(:product) { create(:product, user: seller, custom_html: page_html) }

    let(:wrapper_path) { "/l/#{product.unique_permalink}" }
    let(:embed_path) { "/l/#{product.unique_permalink}/landing/embed" }

    it_behaves_like "a surface carrying both halves of the bridge"
  end
end
