# frozen_string_literal: true

require "spec_helper"

# GET /v2/user/profile_layout — the seller's default (non-custom-HTML) storefront layout: their
# tabs, the sections in each, and each section's heading.
#
# This exists because that surface was invisible to every API caller. The store agent could read
# only the profile's custom HTML, so for a seller who had never published any, it saw nothing and
# reported the storefront as Gumroad's untouched default. A seller who asked about the "Albums"
# heading on his own live page — his own section header — was told it did not exist, that the
# default template said "Products" instead, and that his browser cache was to blame
# (gumroad-private#1466).
describe Api::V2::UsersController, "GET 'profile_layout'" do
  let(:seller) { create(:named_seller) }
  let(:app) { create(:oauth_application, owner: create(:user)) }

  it "returns 401 without a token" do
    get :profile_layout

    expect(response.status).to eq(401)
  end

  context "with a valid token" do
    let(:token) { create("doorkeeper/access_token", application: app, resource_owner_id: seller.id, scopes: "view_profile") }

    def layout
      get :profile_layout, params: { access_token: token.token }
      expect(response).to be_successful
      response.parsed_body["profile_layout"]
    end

    # The heading the seller could see and the agent insisted was not there. This is the whole point
    # of the endpoint, so it is asserted with the reported seller's own shape: one tab, one products
    # section, a header they typed.
    it "returns the seller's own section headers, which are the headings visitors see" do
      section = create(:seller_profile_products_section, seller:, header: "Albums")
      seller.seller_profile.update!(json_data: { "tabs" => [{ "name" => "Music", "sections" => [section.id] }] })

      expect(layout["tabs"]).to eq([{ "name" => "Music", "sections" => [{ "header" => "Albums", "type" => "SellerProfileProductsSection" }] }])
    end

    it "reports a section whose header the seller hid as having no heading" do
      section = create(:seller_profile_products_section, seller:, header: "Albums", hide_header: true)
      seller.seller_profile.update!(json_data: { "tabs" => [{ "name" => "Music", "sections" => [section.id] }] })

      expect(layout["tabs"].first["sections"].first["header"]).to be_nil
    end

    it "reports a blank header as no heading rather than an empty string" do
      section = create(:seller_profile_products_section, seller:, header: "")
      seller.seller_profile.update!(json_data: { "tabs" => [{ "name" => "Music", "sections" => [section.id] }] })

      expect(layout["tabs"].first["sections"].first["header"]).to be_nil
    end

    # The public profile hides the tab bar until there are two tabs, which is why the reported
    # seller's single named tab appeared to have vanished from his own storefront.
    it "says the tab bar is hidden while the seller has only one tab" do
      section = create(:seller_profile_products_section, seller:)
      seller.seller_profile.update!(json_data: { "tabs" => [{ "name" => "Music", "sections" => [section.id] }] })

      expect(layout["tab_bar_visible"]).to be(false)
    end

    it "says the tab bar is visible once the seller has two tabs" do
      first = create(:seller_profile_products_section, seller:)
      second = create(:seller_profile_products_section, seller:)
      seller.seller_profile.update!(json_data: { "tabs" => [
                                      { "name" => "Music", "sections" => [first.id] },
                                      { "name" => "Merch", "sections" => [second.id] },
                                    ] })

      expect(layout["tab_bar_visible"]).to be(true)
    end

    # Which surface the visitor is actually looking at. Without this a caller could describe a tab
    # layout that a published custom HTML takeover has replaced.
    it "reports that tabs and sections are what renders when there is no custom HTML" do
      expect(layout["rendering"]).to eq("tabs_and_sections")
    end

    it "reports that custom HTML renders instead once the seller has published some" do
      Page.create!(pageable: seller, custom_html: "<h1>Hi</h1>")

      expect(layout["rendering"]).to eq("custom_html")
    end

    # A seller with nothing set up must come back as an empty layout, never as an error — the
    # blindness this endpoint fixes was itself read as "there is nothing there".
    it "returns an empty layout for a seller who has never touched their profile" do
      expect(layout["tabs"]).to eq([])
      expect(layout["tab_bar_visible"]).to be(false)
    end

    # A tab's `sections` array holds raw ids, and the section rows are deleted independently of the
    # tab layout, so a dangling id is an ordinary state rather than corruption.
    it "skips a section id in the tab layout whose section row no longer exists" do
      section = create(:seller_profile_products_section, seller:, header: "Albums")
      seller.seller_profile.update!(json_data: { "tabs" => [{ "name" => "Music", "sections" => [section.id, section.id + 10_000] }] })

      expect(layout["tabs"].first["sections"].length).to eq(1)
    end

    # Sections attached to a product are a different surface (the product page's own sections) and
    # are not part of the profile, so they must not leak into this layout.
    it "does not include another seller's sections or a product's sections" do
      other_seller_section = create(:seller_profile_products_section, seller: create(:user), header: "Not mine")
      product_section = create(:seller_profile_products_section, seller:, product: create(:product, user: seller), header: "On a product")
      profile_section = create(:seller_profile_products_section, seller:, header: "Albums")
      seller.seller_profile.update!(json_data: { "tabs" => [{ "name" => "Music", "sections" => [other_seller_section.id, product_section.id, profile_section.id] }] })

      expect(layout["tabs"].first["sections"]).to eq([{ "header" => "Albums", "type" => "SellerProfileProductsSection" }])
    end

    it "says the seller edits this themselves and that the caller has no endpoint for it" do
      expect(layout["editable_by_seller"]).to be(true)
      expect(layout["how_to_change"]).to include("no endpoint")
    end
  end
end
