# frozen_string_literal: true

require "spec_helper"

describe("Top creator badge on Discover and Product pages", js: true, type: :system) do
  include StripeMerchantAccountHelper

  let(:discover_host) { UrlService.discover_domain_with_protocol }

  before do
    allow_any_instance_of(Link).to receive(:update_asset_preview)
  end

  let!(:three_d_taxonomy) { Taxonomy.find_by(slug: "3d") }

  it "shows top creator badge on discover card and product page" do
    top_creator = create(:compliant_user, name: "Top Creator", verified: true)
    regular_creator = create(:compliant_user, name: "Regular Creator", verified: false)
    top_creator_product = create(:product, user: top_creator, name: "Top Creator Product", taxonomy: three_d_taxonomy)
    regular_product = create(:product, user: regular_creator, name: "Regular Product", taxonomy: three_d_taxonomy)

    create(:purchase, email: "buyer@example.com", link: top_creator_product)
    create(:purchase, email: "buyer2@example.com", link: regular_product)

    index_model_records(Link)

    visit discover_url(host: discover_host, query: "Creator")
    wait_for_ajax

    # Top creator badge visible on the top creator's product card
    top_card = find_product_card(top_creator_product)
    within(top_card) do
      expect(page).to have_css(".top-creator-badge")
    end

    # No badge on the regular creator's product card
    regular_card = page.find("article", text: "Regular Product")
    within(regular_card) do
      expect(page).not_to have_css(".top-creator-badge")
    end

    # Click through to the product page
    within(top_card) do
      click_on top_creator_product.name
    end
    wait_for_ajax

    # Top creator badge visible on the product page
    expect(page).to have_css(".top-creator-badge")
  end
end
