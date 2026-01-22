# frozen_string_literal: true

require "spec_helper"

describe("Black Friday 2025", js: true, type: :system) do
  let(:discover_host) { UrlService.discover_domain_with_protocol }

  before do
    allow_any_instance_of(Link).to receive(:update_asset_preview)
    @creator = create(:compliant_user, name: "Black Friday Seller")
    @buyer = create(:user)
  end

  describe "Black Friday hero section" do
    before do
      Feature.activate(:offer_codes_search)

      product = create(:product, :recommendable, user: @creator, price_cents: 1000)
      offer_code = create(:offer_code, user: @creator, code: "BLACKFRIDAY2025", amount_percentage: 25, products: [product])
      create_list(:purchase, 5, link: product, offer_code:, price_cents: 750)

      # Stub the stats service to return the expected values
      allow(BlackFridayStatsService).to receive(:fetch_stats).and_return({
                                                                           active_deals_count: 1,
                                                                           revenue_cents: 3750, # 5 purchases * 750 cents = $37.50
                                                                           average_discount_percentage: 25
                                                                         })
    end

    after do
      Feature.deactivate(:offer_codes_search)
      Rails.cache.delete("black_friday_stats")
    end

    it "shows hero on discover page with CTA when feature is enabled", :sidekiq_inline do
      index_model_records(Link)

      visit discover_url(host: discover_host)
      wait_for_ajax

      expect(page).to have_selector("header img[alt='Black Friday']")
      expect(page).to have_text("Snag creator-made deals")
      expect(page).to have_link("Get Black Friday deals", href: discover_path(offer_code: SearchProducts::BLACK_FRIDAY_CODE))
      expect(page).to have_text("BLACK FRIDAY IS LIVE")
      expect(page).to have_text("1")
      expect(page).to have_text("ACTIVE DEALS")
      expect(page).to have_text("$37.50")
      expect(page).to have_text("IN SALES SO FAR")
      expect(page).to have_text("25%")
      expect(page).to have_text("AVERAGE DISCOUNT")

      # When visiting a taxonomy page, the CTA should be the taxonomy page with the offer code
      click_on("Films")
      expect(page).to have_link("Get Black Friday deals", href: discover_taxonomy_path(taxonomy: "films", offer_code: SearchProducts::BLACK_FRIDAY_CODE))
    end

    it "shows hero on blackfriday page without CTA when feature is enabled", :sidekiq_inline do
      index_model_records(Link)

      visit blackfriday_url(host: discover_host)
      wait_for_ajax

      expect(page).to have_selector("header img[alt='Black Friday']")
      expect(page).to have_text("Snag creator-made deals")
      expect(page).not_to have_link("Get Black Friday deals")
      expect(page).to have_text("BLACK FRIDAY IS LIVE")
      expect(page).to have_text("1")
      expect(page).to have_text("ACTIVE DEALS")
    end

    it "hides hero when feature is disabled", :sidekiq_inline do
      Feature.deactivate(:offer_codes_search)
      create(:product, :recommendable, user: @creator)
      index_model_records(Link)

      visit discover_url(host: discover_host)
      wait_for_ajax

      expect(page).not_to have_selector("header img[alt='Black Friday']")
      expect(page).not_to have_text("Snag creator-made deals")
      expect(page).not_to have_text("BLACK FRIDAY IS LIVE")
    end
  end

  describe "BLACKFRIDAY2025 offer code filtering" do
    before do
      Feature.activate(:offer_codes_search)
    end

    after do
      Feature.deactivate(:offer_codes_search)
    end

    it "filters products by BLACKFRIDAY2025 offer code, hides featured products, and includes offer code in product links", :sidekiq_inline, :elasticsearch_wait_for_refresh do
      product = create(:product, :recommendable, user: @creator, name: "Black Friday Special Product", price_cents: 5000)
      index_model_records(Link)

      # Visit the blackfriday URL before offer code association
      visit blackfriday_url(host: discover_host)
      wait_for_ajax

      expect(page).not_to have_product_card(text: "Black Friday Special Product")

      # Create the BLACKFRIDAY2025 offer code and associate it with the product
      blackfriday_offer_code = create(:offer_code, user: @creator, code: "BLACKFRIDAY2025", amount_percentage: 25)
      product.offer_codes << blackfriday_offer_code

      # Create some purchases to make the product potentially appear as featured
      create_list(:purchase, 5, link: product)

      # Re-index the product and purchases to include the offer code in search
      product.enqueue_index_update_for(["offer_codes"])
      index_model_records(Link)
      index_model_records(Purchase)
      visit blackfriday_url(host: discover_host)
      wait_for_ajax

      expect(page).not_to have_section("Featured products")

      expect(page).to have_product_card(text: "Black Friday Special Product")

      find_product_card(product).click

      expect(page).to have_current_path(/.*\?.*code=BLACKFRIDAY2025/)
      expect(page).to have_text("$1 off will be applied at checkout (Code BLACKFRIDAY2025)")
    end
  end
end
