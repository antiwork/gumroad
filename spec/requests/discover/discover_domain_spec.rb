# frozen_string_literal: true

require "spec_helper"

describe "DiscoverDomainScenario", type: :system, js: true do
  let(:films_best_selling_section) do
    find("section", text: "Best selling products")
  end

  before do
    @port = Capybara.current_session.server.port

    @discover_domain = "discover.test.gumroad.com"
    stub_const("VALID_DISCOVER_REQUEST_HOST", @discover_domain)

    @product1 = create(:product, :recommendable, name: "product 1")
    @product2 = create(:product, :recommendable, name: "product 2")

    index_model_records(Link)
  end

  def expect_discover_page_logged_in_links(page)
    host = UrlService.domain_with_protocol

    expect(page).to have_selector "a[aria-label='Primary logo'][href='#{dashboard_url(host:)}']"
    expect(page).to have_link "Discover", href: UrlService.discover_domain_with_protocol
    expect(page).to have_link "Library", href: library_url(host:)
    expect(page).to have_link "Settings", href: settings_main_url(host:)
    expect(page).to have_link "Logout", href: logout_url(host:)
  end

  def expect_product_and_creator_links(product, recommended_by: "discover")
    expect(page).to have_link product.user.name, href: product.user.profile_url(recommended_by:)
    find_product_card(product).hover
    expect(page).to have_selector "a[href='#{product.long_url(recommended_by:, layout: "discover")}']"
  end

  describe "on discover domain" do
    it "correctly attributes purchase to discover and search" do
      featured_products = create_list(:product, 6, :recommendable, price_cents: 99)
      other_product = create(:product, :recommendable, name: "not featured product")

      # Set sales_volume to make sure featured products are predictable
      [@product1, @product2, *featured_products].each { create(:purchase, link: _1) }
      index_model_records(Purchase)
      index_model_records(Link)

      visit "http://#{@discover_domain}:#{@port}/#{@product1.taxonomy.slug}"

      within_section "Featured products", section_element: :section do
        expect_product_and_creator_links(@product1)
        expect_product_and_creator_links(@product2)
      end

      within_section "On the market" do
        expect_product_and_creator_links(other_product, recommended_by: "search")
      end

      within_section "Featured products", section_element: :section do
        find_product_card(@product1).click
      end

      wait_for_ajax
      expect do
        add_to_cart(@product1, cart: true)
        check_out(@product1, credit_card: { number: "4000002500003155" }, sca: true)
      end.to change { Purchase.successful.select(&:was_discover_fee_charged?).count }.by(1)
         .and change { Purchase.successful.select(&:was_product_recommended?).count }.by(1)
         .and change { RecommendedPurchaseInfo.where(recommendation_type: "discover").count }.by(1)
    end
  end
end
