# frozen_string_literal: true

require "spec_helper"

describe("Black Friday 2025", js: true, type: :system) do
  let(:discover_host) { UrlService.discover_domain_with_protocol }

  before do
    allow_any_instance_of(Link).to receive(:update_asset_preview)
    @creator = create(:compliant_user, name: "Black Friday Seller")
    @buyer = create(:user)
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
      visit "#{discover_host}/blackfriday"
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
      visit "#{discover_host}/blackfriday"
      wait_for_ajax

      expect(page).not_to have_section("Featured products")

      expect(page).to have_product_card(text: "Black Friday Special Product")

      find_product_card(product).click

      expect(page).to have_current_path(/.*\?.*code=BLACKFRIDAY2025/)
      expect(page).to have_text("$1 off will be applied at checkout (Code BLACKFRIDAY2025)")
    end
  end
end
