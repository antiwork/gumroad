# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/products_navigation"

describe "Affiliated Products", type: :system, js: true do
  let(:affiliate_user) { create(:affiliate_user) }

  include_context "with switching account to user as admin for seller" do
    let(:seller) { affiliate_user }
  end

  it_behaves_like "tab navigation on products page" do
    let(:url) { products_affiliated_index_path }
  end

  shared_examples "accesses global affiliates page" do
    it "provides details about the program" do
      visit products_affiliated_index_path
      expect(page).to have_tab_button("Affiliated", open: true)

      click_on "Gumroad affiliate"

      expect(page).to have_content "Gumroad Affiliates"
      expect(page).to have_content "Affiliate link"
      expect(page).to have_content "Affiliate link generator"
      expect(page).to have_content "How to know if a product is eligible"
    end
  end

  context "when the user has affiliated products" do
    let(:creator) { create(:named_user) }
    let(:creator_products) { create_list(:product, 10, user: creator, price_cents: 1000) }
    let(:affiliate_one_products) { creator_products.shuffle.first(3) }
    let(:affiliate_two_products) { (creator_products - affiliate_one_products).shuffle.first(2) }
    let(:affiliate_three_products) { (creator_products - affiliate_one_products - affiliate_two_products) }
    # ensure global affiliate products appear first for testing purposes by explicitly setting affiliate creation dates
    let(:direct_affiliate) { create(:direct_affiliate, affiliate_user:, seller: creator, affiliate_basis_points: 2500, created_at: 3.days.ago) }
    let(:global_affiliate) { affiliate_user.global_affiliate }

    before do
      affiliate_one_products.each do |product|
        create(:product_affiliate, affiliate: direct_affiliate, product:, affiliate_basis_points: 25_00)
      end
      affiliate_two_products.each do |product|
        create(:product_affiliate, affiliate: direct_affiliate, product:, affiliate_basis_points: 5_00)
      end
      create(:product_affiliate, affiliate: direct_affiliate, product: affiliate_three_products.first, affiliate_basis_points: 20_00)

      purchases = []

      purchases << create(:purchase_in_progress, seller: creator, link: affiliate_one_products.first, affiliate: global_affiliate)
      purchases << create(:purchase_in_progress, seller: creator, link: affiliate_one_products.first, affiliate: direct_affiliate)

      2.times do
        purchases << create(:purchase_in_progress, seller: creator, link: affiliate_two_products.first, affiliate: direct_affiliate)
      end

      4.times do
        purchases << create(:purchase_in_progress, seller: creator, link: affiliate_three_products.first, affiliate: direct_affiliate)
      end

      purchases.each do |purchase|
        purchase.process!
        purchase.update_balance_and_mark_successful!
      end
    end

    it "displays stats about affiliated products and sales and correct table rows data" do
      visit products_affiliated_index_path

      within "[aria-label='Stats']" do
        within_section "Revenue" do
          expect(page).to have_content "9.86"
        end

        within_section "Sales" do
          expect(page).to have_content 8
        end

        within_section "Products" do
          expect(page).to have_content 6
        end

        within_section "Affiliated creators" do
          expect(page).to have_content 1
        end
      end

      within "table" do
        expect(page).to have_selector(:table_row, { "Product" => affiliate_one_products.first.name,   "Sales" => "1", "Type" => "Gumroad", "Commission" => "10%", "Revenue" => "$0.79" })
        expect(page).to have_selector(:table_row, { "Product" => affiliate_one_products.first.name,   "Sales" => "1", "Type" => "Direct", "Commission" => "25%", "Revenue" => "$1.97" })
        expect(page).to have_selector(:table_row, { "Product" => affiliate_one_products.second.name,  "Sales" => "0", "Type" => "Direct", "Commission" => "25%", "Revenue" => "$0" })
        expect(page).to have_selector(:table_row, { "Product" => affiliate_one_products.third.name,   "Sales" => "0", "Type" => "Direct", "Commission" => "25%", "Revenue" => "$0" })
        expect(page).to have_selector(:table_row, { "Product" => affiliate_two_products.first.name,   "Sales" => "2", "Type" => "Direct", "Commission" => "5%",  "Revenue" => "$0.78" })
        expect(page).to have_selector(:table_row, { "Product" => affiliate_two_products.second.name,  "Sales" => "0", "Type" => "Direct", "Commission" => "5%",  "Revenue" => "$0" })
        expect(page).to have_selector(:table_row, { "Product" => affiliate_three_products.first.name, "Sales" => "4", "Type" => "Direct", "Commission" => "20%", "Revenue" => "$6.32" })
      end
    end

    context "pagination" do
      before { stub_const("AffiliatedProductsPresenter::PER_PAGE", 5) }

      it "returns paginated affiliated products" do
        affiliate_three_products[1..].each do |product|
          create(:product_affiliate, affiliate: direct_affiliate, product:, affiliate_basis_points: 2000)
        end

        visit products_affiliated_index_path

        expect(page).to have_selector("table > tbody > tr", count: 5)

        click_on "2"

        expect(page).to have_selector("table > tbody > tr", count: 5)

        click_on "3"

        expect(page).to have_selector("table > tbody > tr", count: 1)

        expect(page).not_to have_selector("button", text: "4")
      end

      it "sets the page to 1 on sort" do
        visit products_affiliated_index_path

        within find("[aria-label='Pagination']") do
          expect(find_button("1")["aria-current"]).to eq("page")
          click_on "2"
          wait_for_ajax
          expect(find_button("1")["aria-current"]).to be_nil
          expect(find_button("2")["aria-current"]).to eq("page")
        end

        find(:columnheader, "Revenue").click
        wait_for_ajax
        within find("[aria-label='Pagination']") do
          expect(find_button("1")["aria-current"]).to eq("page")
          expect(find_button("2")["aria-current"]).to be_nil
        end
      end
    end

    it "supports searching affiliated products" do
      visit products_affiliated_index_path
      new_product = create(:product, user: creator, name: "A very unique product name")
      create(:product_affiliate, affiliate: direct_affiliate, product: new_product, affiliate_basis_points: 25_00)
      select_disclosure "Search" do
        fill_in "Search", with: new_product.name
      end

      expect(page).to have_selector("table > tbody > tr", count: 1)
      within "table" do
        expect(page).to have_selector(:table_row, { "Product" => new_product.name, "Sales" => "0", "Type" => "Direct", "Commission" => "25%", "Revenue" => "$0" })
      end

      fill_in "Search", with: ""
      expect(page).to have_selector("table > tbody > tr", count: 8)
    end

    it "sorts affiliated products by column" do
      visit products_affiliated_index_path

      expect(page).to have_nth_table_row_record(1, affiliate_three_products.first.name)
      expect(page).to have_nth_table_row_record(2, affiliate_two_products.first.name)
      expect(page).to have_nth_table_row_record(3, affiliate_one_products.first.name)

      find(:columnheader, "Product").click

      expect(page).to have_nth_table_row_record(1, affiliate_one_products.first.name)
      expect(page).to have_nth_table_row_record(2, affiliate_two_products.first.name)
      expect(page).to have_nth_table_row_record(3, affiliate_three_products.first.name)

      find(:columnheader, "Sales").click

      expect(page).to have_nth_table_row_record(1, affiliate_three_products.first.name)
      expect(page).to have_nth_table_row_record(2, affiliate_two_products.first.name)
      expect(page).to have_nth_table_row_record(3, affiliate_one_products.first.name)

      find(:columnheader, "Sales").click

      expect(page).to have_nth_table_row_record(1, affiliate_one_products.first.name)
      expect(page).to have_nth_table_row_record(2, affiliate_two_products.first.name)
      expect(page).to have_nth_table_row_record(3, affiliate_three_products.first.name)

      find(:columnheader, "Commission").click

      expect(page).to have_nth_table_row_record(1, affiliate_one_products.first.name)
      expect(page).to have_nth_table_row_record(2, affiliate_two_products.first.name)
      expect(page).to have_nth_table_row_record(3, affiliate_three_products.first.name)

      find(:columnheader, "Commission").click

      expect(page).to have_nth_table_row_record(1, affiliate_three_products.first.name)
      expect(page).to have_nth_table_row_record(2, affiliate_two_products.first.name)
      expect(page).to have_nth_table_row_record(3, affiliate_one_products.first.name)

      find(:columnheader, "Revenue").click

      expect(page).to have_nth_table_row_record(1, affiliate_one_products.first.name)
      expect(page).to have_nth_table_row_record(2, affiliate_two_products.first.name)
      expect(page).to have_nth_table_row_record(3, affiliate_three_products.first.name)

      find(:columnheader, "Revenue").click

      expect(page).to have_nth_table_row_record(1, affiliate_three_products.first.name)
      expect(page).to have_nth_table_row_record(2, affiliate_two_products.first.name)
      expect(page).to have_nth_table_row_record(3, affiliate_one_products.first.name)
    end

    it "copies the affiliated product link" do
      visit products_affiliated_index_path

      within first("table > tbody > tr") do
        click_on "Copy link"
      end

      expect(page).to have_text("Copied!")
    end

    it "allows opening the product on clicking product's title" do
      visit products_affiliated_index_path

      find(:columnheader, "Revenue").click
      find(:columnheader, "Revenue").click

      product = affiliate_three_products.first
      within find(:table_row, { "Product" => product.name }, match: :first) do
        expect(page).to have_link(product.name, href: direct_affiliate.referral_url_for_product(product))
      end
    end

    it "allows opening product on clicking product's title based on the destination URL setting" do
      # When Destination URL is set
      direct_affiliate.update!(destination_url: "https://gumroad.com", apply_to_all_products: true)
      product = affiliate_three_products.first

      # Set unique product name to avoid flakiness
      product.update!(name: "Beautiful banner")

      visit products_affiliated_index_path

      find(:columnheader, "Revenue").click
      find(:columnheader, "Revenue").click

      within find(:table_row, { "Product" => "Beautiful banner" }) do
        new_window = window_opened_by { click_link product.name }

        within_window new_window do
          expect(page).to have_current_path("https://gumroad.com?affiliate_id=#{direct_affiliate.external_id_numeric}")
        end
      end

      # When Destination URL is not set
      direct_affiliate.update!(destination_url: nil)
      refresh

      within find(:table_row, { "Product" => "Beautiful banner" }) do
        new_window = window_opened_by { click_link product.name }

        within_window new_window do
          expect(page).to have_current_path(product.long_url)
        end
      end
    end

    it "displays products with global affiliate sales by the user" do
      visit products_affiliated_index_path

      expect(page).to have_selector("td[data-label='Type']", text: "Gumroad")
      expect(page).to have_selector("td[data-label='Sales']", text: "1")
    end

    it_behaves_like "accesses global affiliates page"
  end

  context "viewing global affiliates" do
    let!(:affiliate) { affiliate_user.global_affiliate }

    it "displays the user's global affiliate link" do
      visit products_affiliated_index_path(affiliates: true)

      expect(page).to have_content "Gumroad Affiliates"
      expect(page).to have_content "#{UrlService.discover_domain_with_protocol}/discover?a=#{affiliate.external_id_numeric}"
    end

    it "displays the amount earned as an affiliate" do
      create_list(:purchase, 2, affiliate:, price_cents: 10_00) # 10% commission * 1 purchases @ $10 - 10% of gumroad fee = $1.58 in affiliate commission

      visit products_affiliated_index_path(affiliates: true)

      expect(page).to have_content "To date, you have made $1.58 from Gumroad referrals."
    end

    context "generating links" do
      it "appends the affiliate query param to a valid Gumroad URL" do
        visit products_affiliated_index_path(affiliates: true)

        [
          { original: "https://#{DISCOVER_DOMAIN}", expected: "https://#{DISCOVER_DOMAIN}/?a=#{affiliate.external_id_numeric}" },
          { original: "https://#{DOMAIN}/l/x", expected: "https://#{DOMAIN}/l/x?a=#{affiliate.external_id_numeric}" },
          { original: "https://edgar.#{ROOT_DOMAIN}", expected: "https://edgar.#{ROOT_DOMAIN}/?a=#{affiliate.external_id_numeric}" },
          { original: "https://#{ROOT_DOMAIN}?foo=bar", expected: "https://#{ROOT_DOMAIN}/?foo=bar&a=#{affiliate.external_id_numeric}" },
          { original: "https://#{ROOT_DOMAIN}?a=#{affiliate.external_id_numeric}", expected: "https://#{ROOT_DOMAIN}/?a=#{affiliate.external_id_numeric}" },
          { original: "https://#{SHORT_DOMAIN}/x", expected: "https://#{SHORT_DOMAIN}/x?a=#{affiliate.external_id_numeric}" },
        ].each do |urls|
          fill_in "Paste a destination page URL", with: urls[:original]
          click_on "Generate link"
          expect(page).to have_content urls[:expected]
        end
      end

      it "returns an error for an invalid or non-Gumroad URL" do
        visit products_affiliated_index_path(affiliates: true)

        [ROOT_DOMAIN, "https://example.com"].each do |url|
          fill_in "Paste a destination page URL", with: url
          click_on "Generate link"
          expect_alert_message("Invalid URL. Make sure your URL is a Gumroad URL and starts with \"http\" or \"https\".")
        end
      end
    end

    describe "checking product eligibility", :realistic_error_responses do
      context "searching by product URL" do
        it "displays product eligibility for a valid, eligible Gumroad URL" do
          product = create(:product, :recommendable)
          product_with_custom_permalink = create(:product, :recommendable, name: "Custom Permalink", custom_permalink: "foo")

          visit products_affiliated_index_path(affiliates: true)

          [
            product.long_url,
            "#{PROTOCOL}://#{ROOT_DOMAIN}/l/#{product.unique_permalink}",
            "#{PROTOCOL}://#{SHORT_DOMAIN}/#{product.unique_permalink}",
            "#{PROTOCOL}://#{DOMAIN}/l/#{product.unique_permalink}",
          ].each do |valid_url|
            fill_in "Paste a product URL", with: "#{valid_url}\n"
            expect(page).not_to have_selector("[role=alert]")
            expect(page).to have_link product.name, href: "#{product.long_url}?a=#{affiliate.external_id_numeric}"
          end
          fill_in "Paste a product URL", with: "#{product_with_custom_permalink.long_url}\n"
          expect(page).not_to have_selector("[role=alert]")
          expect(page).to have_link product_with_custom_permalink.name, href: "#{product_with_custom_permalink.long_url}?a=#{affiliate.external_id_numeric}"
        end

        it "displays a warning for an invalid URL" do
          product = create(:product, :recommendable)

          visit products_affiliated_index_path(affiliates: true)

          [
            { url: "", message: "URL must be provided" },
            { url: "#{PROTOCOL}://#{ROOT_DOMAIN}/l/foo", message: "Please provide a valid Gumroad product URL" },
            { url: "#{PROTOCOL}://example.com/l/#{product.unique_permalink}", message: "Please provide a valid Gumroad product URL" },
          ].each do |invalid_option|
            fill_in "Paste a product URL", with: "#{invalid_option[:url]}\n"
            wait_for_ajax
            expect_alert_message(invalid_option[:message])
          end
        end

        it "displays a warning for an ineligible product" do
          product = create(:product)

          visit products_affiliated_index_path(affiliates: true)

          fill_in "Paste a product URL", with: "#{product.long_url}\n"
          wait_for_ajax
          expect_alert_message("This product is not eligible for the Gumroad Affiliate Program.")
        end
      end
    end
  end
end
