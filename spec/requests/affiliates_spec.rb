# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe "Affiliates", type: :system, js: true do
  it "redirects to the product page and applies discount based on the offer_code parameter in the query string" do
    user = create(:user)
    product = create(:product, user:, price_cents: 2000)
    direct_affiliate = create(:direct_affiliate, seller_id: user.id, products: [product])
    offer_code = create(:offer_code, code: "free", products: [product], amount_cents: 2000)

    visit direct_affiliate.referral_url
    expect(page).to(have_selector("[itemprop='price']", text: "$20"))

    visit "#{direct_affiliate.referral_url}/?offer_code=#{offer_code.code}"
    expect(page).to have_selector("[role='status']", text: "$20 off will be applied at checkout (Code FREE)")
    expect(page).to have_selector("[itemprop='price']", text: "$20 $0")
    click_on "I want this!"
    fill_in("Your email address", with: "test@gumroad.com")
    click_on "Get"
    expect(page).to have_alert(text: "Your purchase was successful!")
  end

  it "displays affiliates based on initial page load query parameters" do
    stub_const("AffiliatesPresenter::PER_PAGE", 1)

    seller = create(:user)
    product = create(:product, user: seller, price_cents: 2000)
    create(:direct_affiliate, seller:, products: [product], affiliate_user: create(:user, name: "Jane"))
    affiliate2 = create(:direct_affiliate, seller:, products: [product], affiliate_user: create(:user, name: "Edgar"))
    affiliate3 = create(:direct_affiliate, seller:, products: [product], affiliate_user: create(:user, name: "Edgar 2"))
    affiliate_request = create(:affiliate_request, seller:)

    sign_in seller
    params = { query: "Edgar", column: "affiliate_user_name", sort: "asc", page: "2" }
    visit affiliates_path(params)

    expect(page).to have_current_path(affiliates_path(params))
    expect(page).to have_tab_button("Affiliates", open: true)
    expect(page).to have_table "Affiliates", with_rows: [
      { "Name" => affiliate3.affiliate_user.name },
    ]
    expect(page).to_not have_table "Requests", with_rows: [{ "Name" => affiliate_request.name }]

    # Ensure that all affiliates and affiliate requests come back when clearing the search
    select_disclosure "Search" do
      fill_in "Search", with: ""
    end

    expect(page).to have_table "Affiliates", with_rows: [
      { "Name" => affiliate2.affiliate_user.name },
    ]
    expect(page).to have_current_path("#{affiliates_path}?column=affiliate_user_name&sort=asc")
    expect(page).to have_table "Requests", with_rows: [{ "Name" => affiliate_request.name }]
  end

  it "allows filtering for affiliates" do
    seller = create(:user)
    product = create(:product, user: seller, price_cents: 2000)
    affiliate1 = create(:direct_affiliate, seller:, products: [product], affiliate_user: create(:user, name: "Jane Affiliate"))
    affiliate2 = create(:direct_affiliate, seller:, products: [product], affiliate_user: create(:user, name: "Edgar"))
    affiliate_request = create(:affiliate_request, seller:)

    sign_in seller
    visit affiliates_path

    expect(page).to have_tab_button("Affiliates", open: true)
    expect(page).to have_table "Affiliates", with_rows: [
      { "Name" => affiliate1.affiliate_user.name, "Product" => product.name, "Commission" => "3%" },
      { "Name" => affiliate2.affiliate_user.name, "Product" => product.name, "Commission" => "3%" },
    ]
    expect(page).to have_table "Requests", with_rows: [{ "Name" => affiliate_request.name }]

    select_disclosure "Search" do
      fill_in "Search", with: "Jane"
    end

    expect(page).to have_table "Affiliates", with_rows: [
      { "Name" => affiliate1.affiliate_user.name, "Product" => product.name, "Commission" => "3%" },
    ]
    expect(page).to have_current_path(affiliates_path({ query: "Jane" }))
    expect(page).to_not have_table "Requests", with_rows: [{ "Name" => affiliate_request.name }]

    # Clear the search and make sure the requests table is back
    fill_in "Search", with: ""
    expect(page).to have_table "Affiliates", with_rows: [
      { "Name" => affiliate1.affiliate_user.name, "Product" => product.name, "Commission" => "3%" },
      { "Name" => affiliate2.affiliate_user.name, "Product" => product.name, "Commission" => "3%" },
    ]
    expect(page).to have_current_path(affiliates_path)
    expect(page).to have_table "Requests", with_rows: [{ "Name" => affiliate_request.name }]
  end

  context "pagination" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller, price_cents: 2000) }
    let!(:affiliate_request) { create(:affiliate_request, seller:) }

    before do
      aff1 = create(:direct_affiliate, seller_id: seller.id, products: [product], affiliate_user: create(:user, name: "Jane Affiliate"))
      ProductAffiliate.find_by(affiliate_id: aff1.id).update!(updated_at: 1.day.ago)
      aff2 = create(:direct_affiliate, seller_id: seller.id, products: [product], affiliate_user: create(:user, name: "Jim Affiliate"))
      ProductAffiliate.find_by(affiliate_id: aff2.id).update!(updated_at: 2.days.ago)
      aff3 = create(:direct_affiliate, seller_id: seller.id, products: [product], affiliate_user: create(:user, name: "Edgar"))
      ProductAffiliate.find_by(affiliate_id: aff3.id).update!(updated_at: 1.week.ago)
      stub_const("AffiliatesPresenter::PER_PAGE", 1)
      sign_in seller
      visit affiliates_path
    end

    it "paginates through the affiliates table" do
      expect(page).to have_button("Previous", disabled: true)
      expect(page).to have_button("Next")
      expect(page).to have_table "Affiliates", with_rows: [
        { "Name" => "Jane Affiliate", "Product" => product.name, "Commission" => "3%" },
      ]

      click_on "2"
      wait_for_ajax

      expect(page).to have_button("Previous")
      expect(page).to have_button("Next")
      expect(page).to have_table "Affiliates", with_rows: [
        { "Name" => "Jim Affiliate", "Product" => product.name, "Commission" => "3%" },
      ]
      expect(page).to have_current_path(affiliates_path({ page: "2" }))
      expect(page).to_not have_table "Requests", with_rows: [{ "Name" => affiliate_request.name }]

      click_on "3"
      wait_for_ajax

      expect(page).to have_button("Previous")
      expect(page).to have_button("Next", disabled: true)
      expect(page).to have_table "Affiliates", with_rows: [
        { "Name" => "Edgar", "Product" => product.name, "Commission" => "3%" },
      ]
      expect(page).to have_current_path(affiliates_path({ page: "3" }))
      expect(page).to_not have_table "Requests", with_rows: [{ "Name" => affiliate_request.name }]

      click_on "1"
      wait_for_ajax

      expect(page).to have_table "Affiliates", with_rows: [
        { "Name" => "Jane Affiliate", "Product" => product.name, "Commission" => "3%" },
      ]
      expect(page).to have_table "Requests", with_rows: [{ "Name" => affiliate_request.name }]
    end

    it "paginates through search results" do
      select_disclosure "Search" do
        fill_in "Search", with: "Affiliate"
      end
      expect(page).to have_table "Affiliate", with_rows: [
        { "Name" => "Jane Affiliate", "Product" => product.name, "Commission" => "3%" },
      ]
      expect(page).to have_button("Previous", disabled: true)
      expect(page).to have_button("Next")
      expect(page).to have_current_path(affiliates_path({ query: "Affiliate" }))
      expect(page).to_not have_table "Requests", with_rows: [{ "Name" => affiliate_request.name }]

      click_on "2"
      wait_for_ajax
      expect(page).to have_table "Affiliate", with_rows: [
        { "Name" => "Jim Affiliate", "Product" => product.name, "Commission" => "3%" },
      ]
      expect(page).to have_button("Previous")
      expect(page).to have_button("Next", disabled: true)
      expect(page).to have_current_path("#{affiliates_path}?query=Affiliate&page=2")
      expect(page).to_not have_table "Requests", with_rows: [{ "Name" => affiliate_request.name }]
    end
  end

  it "can view individual affiliates and sort them by sales" do
    seller = create(:user)
    product = create(:product, name: "Gumbot bits", user: seller, price_cents: 10_00)
    product_2 = create(:product, name: "100 ChatGPT4 prompts to increase productivity", user: seller, price_cents: 5_00)

    affiliate_user1 = create(:user, name: "Jane Affiliate")
    affiliate_user2 = create(:user, name: "Edgar")
    affiliate_user3 = create(:user, name: "Sally Affiliate")
    affiliate1 = create(:direct_affiliate, seller:, products: [product, product_2], affiliate_user: affiliate_user1)
    affiliate2 = create(:direct_affiliate, seller:, products: [product], affiliate_user: affiliate_user2)
    create(:direct_affiliate, seller:, products: [product], affiliate_user: affiliate_user3)

    create_list(:purchase_with_balance, 2, affiliate_credit_cents: 100, affiliate: affiliate1, link: product)
    create(:purchase_with_balance, affiliate_credit_cents: 100, affiliate: affiliate1, link: product_2)
    create(:purchase_with_balance, affiliate_credit_cents: 100, affiliate: affiliate2, link: product)

    sign_in seller
    visit affiliates_path
    expect(page).to have_table "Affiliates", with_rows: [
      { "Name" => affiliate_user1.name, "Product" => "2 products", "Commission" => "3%", "Sales" => "$25" },
      { "Name" => affiliate_user2.name, "Product" => product.name, "Commission" => "3%", "Sales" => "$10" },
      { "Name" => affiliate_user3.name, "Product" => product.name, "Commission" => "3%", "Sales" => "$0" },
    ]

    find(:table_row, { "Name" => affiliate_user1.name, "Product" => "2 products" }).click
    within_section affiliate_user1.name, section_element: :aside do
      within_section product.name do
        expect(page).to have_text("Revenue $20", normalize_ws: true)
        expect(page).to have_text("Sales 2", normalize_ws: true)
        expect(page).to have_text("Commission 3%", normalize_ws: true)
        expect(page).to have_button("Copy link")
      end
      within_section product_2.name do
        expect(page).to have_text("Revenue $5", normalize_ws: true)
        expect(page).to have_text("Sales 1", normalize_ws: true)
        expect(page).to have_text("Commission 3%", normalize_ws: true)
        expect(page).to have_button("Copy link")
      end

      expect(page).to have_link("Edit")
      expect(page).to have_button("Delete")
    end

    find(:table_row, { "Name" => affiliate_user2.name, "Product" => product.name }).click
    within_section affiliate_user2.name, section_element: :aside do
      within_section product.name do
        expect(page).to have_text("Revenue $10", normalize_ws: true)
        expect(page).to have_text("Sales 1", normalize_ws: true)
        expect(page).to have_text("Commission 3%", normalize_ws: true)
        expect(page).to have_button("Copy link")
      end

      expect(page).to have_link("Edit")
      expect(page).to have_button("Delete")
    end

    find(:table_row, { "Name" => affiliate_user3.name, "Product" => product.name }).click
    within_section affiliate_user3.name, section_element: :aside do
      within_section product.name do
        expect(page).to have_text("Revenue $0", normalize_ws: true)
        expect(page).to have_text("Sales 0", normalize_ws: true)
        expect(page).to have_text("Commission 3%", normalize_ws: true)
        expect(page).to have_button("Copy link")
      end

      expect(page).to have_link("Edit")
      expect(page).to have_button("Delete")
    end
  end

  context "creating an affiliate" do
    let(:seller) { create(:named_seller) }

    include_context "with switching account to user as admin for seller"

    context "when the creator already has affiliates" do
      let!(:product_one) { create(:product, user: seller, name: "a product") }
      let!(:product_two) { create(:product, user: seller, name: "second_product") }
      let!(:archived_product) { create(:product, user: seller, name: "Archived product", archived: true) }
      let!(:collab_product) { create(:product, :is_collab, user: seller, name: "Collab product") }
      let(:existing_affiliate_user) { create(:user, name: "Jane Affiliate", email: "existing_affiliate_user@gum.co") }
      let!(:existing_affiliate) do
        create(:direct_affiliate, affiliate_user: existing_affiliate_user, seller:,
                                  affiliate_basis_points: 1500, destination_url: "https://example.com")
      end
      let(:new_affiliate_user) { create(:user, name: "Joe Affiliate", email: "new_affiliate@gum.co") }
      let!(:affiliate_request) { create(:affiliate_request, seller:) }

      before { create(:product_affiliate, product: product_one, affiliate: existing_affiliate, affiliate_basis_points: 1500) }

      it "creates a new affiliate for all eligible products" do
        visit affiliates_path
        wait_for_ajax

        click_on "Add affiliate"

        fill_in "Email", with: new_affiliate_user.email

        expect(page).not_to have_content "Collab product" # excludes ineligible products

        within :table_row, { "Product" => "All products" } do
          check "Enable all products"
          fill_in "Commission", with: "10"
          fill_in "https://link.com", with: "foo"
        end

        click_on "Add affiliate"

        within :table_row, { "Product" => "All products" } do
          # validates URL
          expect(find("fieldset.danger")).to have_field("https://link.com", with: "foo")

          fill_in "https://link.com", with: "https://my-site.com#section?foo=bar&baz=qux"
        end
        click_on "Add affiliate"

        # Show the most recently updated affiliate as the first row
        expect(page).to have_table "Affiliates", with_rows: [
          { "Name" => new_affiliate_user.name, "Products" => "2 products", "Commission" => "10%" },
          { "Name" => existing_affiliate_user.name, "Products" => product_one.name, "Commission" => "15%" }
        ]
        expect(page).to have_table "Requests", with_rows: [{ "Name" => affiliate_request.name }]

        find(:table_row, { "Name" => new_affiliate_user.name, "Product" => "2 products" }).click
        within_section new_affiliate_user.name, section_element: :aside do
          within_section product_one.name do
            expect(page).to have_text("Revenue $0", normalize_ws: true)
            expect(page).to have_text("Sales 0", normalize_ws: true)
            expect(page).to have_text("Commission 10%", normalize_ws: true)
            expect(page).to have_button("Copy link")
          end

          within_section product_two.name do
            expect(page).to have_text("Revenue $0", normalize_ws: true)
            expect(page).to have_text("Sales 0", normalize_ws: true)
            expect(page).to have_text("Commission 10%", normalize_ws: true)
            expect(page).to have_button("Copy link")
          end

          expect(page).to have_link("Edit")
          expect(page).to have_button("Delete")
        end

        new_direct_affiliate = DirectAffiliate.find_by(affiliate_user_id: new_affiliate_user.id)
        expect(new_direct_affiliate.apply_to_all_products).to be true
        expect(new_direct_affiliate.destination_url).to eq "https://my-site.com#section?foo=bar&baz=qux"
        expect(new_direct_affiliate.products).to match_array [product_one, product_two]
      end

      it "creates a new affiliate for one specific enabled product" do
        visit affiliates_path
        wait_for_ajax

        click_on "Add affiliate"

        fill_in "Email", with: new_affiliate_user.email

        within :table_row, { "Product" => "All products" } do
          check "Enable all products"
          fill_in "Commission", with: "10"
          uncheck "Enable all products"
        end

        within :table_row, { "Product" => product_one.name } do
          check "Enable product"
          fill_in "Commission", with: "5"
        end
        fill_in "https://link.com", with: "http://google.com/"
        click_on "Add affiliate"

        # Show the most recently updated affiliate as the first row
        expect(page).to have_table "Affiliates", with_rows: [
          { "Name" => new_affiliate_user.name, "Product" => product_one.name, "Commission" => "5%" },
          { "Name" => existing_affiliate_user.name, "Product" => product_one.name, "Commission" => "15%" }
        ]

        find(:table_row, { "Name" => new_affiliate_user.name, "Product" => product_one.name }).click
        within_section new_affiliate_user.name, section_element: :aside do
          within_section product_one.name do
            expect(page).to have_text("Revenue $0", normalize_ws: true)
            expect(page).to have_text("Sales 0", normalize_ws: true)
            expect(page).to have_text("Commission 5%", normalize_ws: true)
            expect(page).to have_button("Copy link")
          end

          expect(page).to have_link("Edit")
          expect(page).to have_button("Delete")
        end

        new_direct_affiliate = DirectAffiliate.find_by(affiliate_user_id: new_affiliate_user.id)
        expect(new_direct_affiliate.apply_to_all_products).to be false
        product_affiliate = new_direct_affiliate.product_affiliates.first
        expect(product_affiliate.link_id).to eq product_one.id
        expect(product_affiliate.affiliate_basis_points).to eq 500
      end

      it "creates a new affiliate for specific enabled products" do
        visit affiliates_path
        wait_for_ajax

        click_on "Add affiliate"

        fill_in "Email", with: new_affiliate_user.email

        within :table_row, { "Product" => product_one.name } do
          check "Enable product"
          fill_in "Commission", with: "15"
          fill_in "https://link.com", with: "https://gumroad.com"
        end
        within :table_row, { "Product" => product_two.name } do
          check "Enable product"
          fill_in "Commission", with: "5"
          fill_in "https://link.com", with: "http://google.com/"
        end
        click_on "Add affiliate"
        wait_for_ajax

        # Show the most recently updated affiliate as the first row
        expect(page).to have_table "Affiliates", with_rows: [
          { "Name" => new_affiliate_user.name, "Products" => "2 products", "Commission" => "5% - 15%" },
          { "Name" => existing_affiliate_user.name, "Products" => product_one.name, "Commission" => "15%" },
        ]

        new_direct_affiliate = DirectAffiliate.find_by(affiliate_user_id: new_affiliate_user.id)

        within :table_row, { "Products" => "2 products" } do
          expect(page).to have_link("2 products", href: new_direct_affiliate.referral_url)
        end
        within :table_row, { "Products" => product_one.name } do
          expect(page).to have_link(product_one.name, href: existing_affiliate.referral_url_for_product(product_one))
        end
        find("td[data-label='Products'] a", match: :first).hover
        expect(page).to have_text("#{product_one.name} (15%), #{product_two.name} (5%)")

        expect(new_direct_affiliate.apply_to_all_products).to be false
        product_affiliate_1, product_affiliate_2 = new_direct_affiliate.product_affiliates.to_a
        expect(product_affiliate_1.link_id).to eq product_one.id
        expect(product_affiliate_1.affiliate_basis_points).to eq 1500
        expect(product_affiliate_1.destination_url).to eq "https://gumroad.com"
        expect(product_affiliate_2.link_id).to eq product_two.id
        expect(product_affiliate_2.affiliate_basis_points).to eq 500
        expect(product_affiliate_2.destination_url).to eq "http://google.com/"
      end

      it "displays an error message if the user is already an affiliate with the same settings" do
        visit affiliates_path
        wait_for_ajax

        click_on "Add affiliate"

        fill_in "Email", with: existing_affiliate_user.email

        within :table_row, { "Product" => product_one.name } do
          check "Enable product"
          fill_in "Commission", with: "15"
          fill_in "https://link.com", with: existing_affiliate.destination_url
        end
        click_on "Add affiliate"

        expect_alert_message("This affiliate already exists.")
      end

      it "does not allow adding an affiliate if creator is using a Brazilian Stripe Connect account" do
        brazilian_stripe_account = create(:merchant_account_stripe_connect, user: seller, country: "BR")
        seller.update!(check_merchant_account_is_linked: true)
        expect(seller.merchant_account(StripeChargeProcessor.charge_processor_id)).to eq brazilian_stripe_account

        visit affiliates_path

        link = find_link("Add affiliate")
        link.hover
        expect(link[:style]).to eq "pointer-events: none; cursor: not-allowed; opacity: 0.3;"
        expect(link).to have_tooltip(text: "Affiliates with Brazilian Stripe accounts are not supported.")
      end
    end
  end

  context "editing an affiliate" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller, name: "a product") }
    let!(:product_2) { create(:product, user: seller, name: "another product") }
    let!(:archived_product) { create(:product, user: seller, name: "Archived product", archived: true) }
    let!(:archived_product_not_selected) { create(:product, user: seller, name: "Archived product not selected", archived: true) }
    let!(:collab_product) { create(:product, :is_collab, user: seller, name: "Collab product") }

    let(:affiliate_user) { create(:user, name: "Gumbot1", email: "affiliate@gum.co") }
    let(:affiliate_user2) { create(:user, name: "Gumbot2", email: "affiliate2@gum.co") }
    let(:direct_affiliate) { create(:direct_affiliate, affiliate_user:, seller:, affiliate_basis_points: 1500) }
    let(:direct_affiliate2) { create(:direct_affiliate, affiliate_user: affiliate_user2, seller:, affiliate_basis_points: 1500) }
    let!(:affiliate_request) { create(:affiliate_request, seller:) }

    include_context "with switching account to user as admin for seller"

    before do
      create(:product_affiliate, affiliate: direct_affiliate, product:, affiliate_basis_points: 1500, destination_url: "https://example.com", updated_at: 4.days.ago)
      create(:product_affiliate, affiliate: direct_affiliate, product:  archived_product, affiliate_basis_points: 1500, destination_url: "https://example.com", updated_at: 3.days.ago)
      create(:product_affiliate, affiliate: direct_affiliate2, product:, affiliate_basis_points: 1500, destination_url: "https://example.com", updated_at: 2.days.ago)
    end

    it "edits an affiliate" do
      visit affiliates_path
      within :table_row, { "Name" => "Gumbot1" } do
        click_on "Edit"
      end

      # make sure the fields are set
      expect(page).to have_field("Email", with: affiliate_user.email, disabled: true)
      expect(page).to have_unchecked_field("Enable all products")

      expect(page).not_to have_content "Collab product" # excludes ineligible products

      within :table_row, { "Product" => "a product" } do
        expect(page).to have_checked_field("Enable product")
        expect(page).to have_field("Commission", with: "15")
        expect(page).to have_field("https://link.com", with: "https://example.com")
      end
      within :table_row, { "Product" => "another product" } do
        expect(page).to have_unchecked_field("Enable product")
        expect(page).to have_field("Commission", with: "15", disabled: true)

        # edit fields
        check "Enable product"
        fill_in "Commission", with: "10"
        fill_in "https://link.com", with: "http://google.com/"
      end
      within :table_row, { "Product" => "Archived product" } do
        expect(page).to have_checked_field("Enable product")
        expect(page).to have_field("Commission", with: "15")
        expect(page).to have_field("https://link.com", with: "https://example.com")
      end
      expect(page).not_to have_table_row({ "Product" => archived_product_not_selected.name })

      click_on "Save changes"

      expect_alert_message("Changes saved!")
      # Show the most recently updated affiliate as the first row
      expect(page).to have_table "Affiliates", with_rows: [
        { "Name" => affiliate_user.name, "Products" => "3 products", "Commission" => "10% - 15%" },
        { "Name" => affiliate_user2.name, "Products" => product.name, "Commission" => "15%" },
      ]
      expect(page).to have_table "Requests", with_rows: [{ "Name" => affiliate_request.name }]

      product_affiliate = direct_affiliate.product_affiliates.find_by(link_id: product_2.id)
      expect(product_affiliate.affiliate_basis_points).to eq 1000
      expect(product_affiliate.destination_url).to eq "http://google.com/"
    end

    it "refreshes table to page 1 after editting an affiliate" do
      stub_const("AffiliatesPresenter::PER_PAGE", 1)

      visit affiliates_path
      click_on "2"
      wait_for_ajax

      click_on "Edit"

      within :table_row, { "Product" => "another product" } do
        check "Enable product"
        fill_in "Commission", with: "10"
        fill_in "https://link.com", with: "http://google.com/"
      end

      click_on "Save changes"

      expect_alert_message("Changes saved!")
      expect(page).to have_current_path(affiliates_path)
      expect(page).to have_button("Previous", disabled: true)
      expect(page).to have_button("Next")
      # Show the most recently updated affiliate as the first row
      expect(page).to have_table "Affiliates", with_rows: [
        { "Name" => affiliate_user.name, "Products" => "3 products", "Commission" => "10% - 15%" },
      ]
      expect(page).to have_table "Requests", with_rows: [{ "Name" => affiliate_request.name }]
    end

    it "can associate an affiliate with all products" do
      visit affiliates_path
      within :table_row, { "Name" => "Gumbot1" } do
        click_on "Edit"
      end
      check "Enable all products"

      click_on "Save changes"
      expect_alert_message("Changes saved!")
      expect(page).to have_table_row({ "Name" => affiliate_user.name, "Products" => "2 products", "Commission" => "15%" })

      expect(direct_affiliate.reload.apply_to_all_products).to be true
      expect(direct_affiliate.affiliate_basis_points).to eq 1500
      expect(direct_affiliate.product_affiliates.count).to eq(2)
    end

    it "can clear affiliate products" do
      visit affiliates_path
      within :table_row, { "Name" => "Gumbot1" } do
        click_on "Edit"
      end

      # select then deselect all products
      check "Enable all products"
      uncheck "Enable all products"

      click_on "Save changes"
      expect_alert_message("Please enable at least one product.")
    end
  end

  context "with switching account to user as admin for seller" do
    let(:seller) { create(:named_seller) }
    let(:affiliate_user) { create(:user, name: "Gumbot Affiliate", email: "old_affiliate@gum.co") }
    let(:product) { create(:product, user: seller, name: "a product") }

    include_context "with switching account to user as admin for seller"

    it "copies an affiliate link" do
      create(:direct_affiliate, affiliate_user:, seller:, affiliate_basis_points: 1500, products: [product])

      visit affiliates_path
      click_on "Copy link"
      expect(page).to have_selector("[role='tooltip']", text: "Copied!")
    end

    it "removes an affiliate from the table" do
      create(:direct_affiliate, affiliate_user:, seller:, affiliate_basis_points: 1500, products: [product])

      visit affiliates_path
      click_on "Delete"
      wait_for_ajax
      expect_alert_message("The affiliate was removed successfully.")
    end

    it "removes an affiliate from the aside drawer" do
      create(:direct_affiliate, affiliate_user:, seller:, affiliate_basis_points: 1500, products: [product])

      visit affiliates_path
      expect(page).to have_table "Affiliates", with_rows: [
        { "Name" => affiliate_user.name, "Product" => product.name, "Commission" => "15%", "Sales" => "$0" }
      ]

      find(:table_row, { "Name" => affiliate_user.name, "Product" => product.name }).click
      within_section affiliate_user.name, section_element: :aside do
        click_on "Delete"
      end
      wait_for_ajax
      expect_alert_message("The affiliate was removed successfully.")
    end

    it "approves all pending affiliates" do
      Feature.activate_user(:auto_approve_affiliates, seller)
      pending_requests = create_list(:affiliate_request, 2, seller:)

      visit affiliates_path

      click_on "Approve all"
      wait_for_ajax

      expect(page).to have_text "Approved"
      pending_requests.each do |request|
        expect(request.reload).to be_approved
      end
    end
  end

  describe "Affiliate requests" do
    let(:seller) { create(:named_seller) }
    let(:affiliate_user) { create(:user) }
    let!(:request_one) { create(:affiliate_request, email: affiliate_user.email, seller:) }
    let!(:request_two) { create(:affiliate_request, name: "Jane Doe", seller:) }
    let!(:request_three) { create(:affiliate_request, name: "Will Smith", seller:) }
    let!(:request_four) { create(:affiliate_request, name: "Rob Cook", seller:) }

    before do
      request_three.approve!
    end

    include_context "with switching account to user as admin for seller"

    it "displays unattended affiliate requests and allows seller to approve and ignore them" do
      visit(affiliates_path)

      expect(page).to have_text("Jane")
      expect(page).to have_text("John")
      expect(page).to have_text("Will")
      expect(page).to have_text("Rob")

      # Sort by name
      find_and_click("th", text: "Name")

      # Verify that Will's request is already approved but because
      # he hasn't created an account yet, it shows disabled "Approved" button
      within all("tr")[4] do
        expect(page).to have_button("Approved", disabled: true)

        # Nothing should happen on clicking the disabled "Approved" button
        click_on("Approved", disabled: true)
        expect(page).to have_text("Will")

        # Ignore Will's request
        expect do
          click_on("Ignore")
          wait_for_ajax
        end.to change { request_three.reload.state }.to eq("ignored")
      end
      expect(page).to_not have_text("Will")

      # Ignore Jane's request
      within all("tr")[1] do
        expect do
          click_on("Ignore")
          wait_for_ajax
        end.to change { request_two.reload.state }.to eq("ignored")
      end
      expect(page).to_not have_text("Jane")

      # Approve John's request
      within all("tr")[1] do
        expect do
          click_on("Approve")
          wait_for_ajax
        end.to change { request_one.reload.state }.to eq("approved")
      end
      expect(page).to_not have_text("John")

      # Approve Rob's request
      within all("tr")[1] do
        expect do
          click_on("Approve")
          wait_for_ajax
        end.to change { request_four.reload.state }.to eq("approved")

        # But because Rob doesn't have an account yet, his request won't go away
        expect(page).to have_text("Rob")

        # Ignore Rob's request
        expect do
          click_on("Ignore")
          wait_for_ajax
        end.to change { request_four.reload.state }.to eq("ignored")
      end
      expect(page).to_not have_text("Rob")

      expect(page).to have_text("No requests yet")
    end
  end

  describe "sorting" do
    let!(:seller) { create(:named_seller) }
    let!(:product1) { create(:product, user: seller, name: "p1", price_cents: 10_00) }
    let!(:product2) { create(:product, user: seller, name: "p2", price_cents: 10_00) }
    let!(:product3) { create(:product, user: seller, name: "p3", price_cents: 10_00) }
    let!(:product4) { create(:product, user: seller, name: "p4", price_cents: 10_00) }
    let!(:affiliate_user_1) { create(:direct_affiliate, seller:, affiliate_user: create(:user, name: "alice"), products: [product1]) }
    let!(:affiliate_user_2) { create(:direct_affiliate, seller:, affiliate_user: create(:user, name: "bob"), products: [product1, product2, product3]) }
    let!(:affiliate_user_3) { create(:direct_affiliate, seller:, affiliate_user: create(:user, name: "david@example.com"), products: [product1, product3]) }
    let!(:affiliate_user_4) { create(:direct_affiliate, seller:, affiliate_user: create(:user, name: "aff4"), products: [product1, product2, product3, product4]) }
    let!(:affiliate_request) { create(:affiliate_request, seller:) }

    before do
      stub_const("AffiliatesPresenter::PER_PAGE", 1)
      ProductAffiliate.where(affiliate_id: affiliate_user_1.id).each.with_index do |affiliate, idx|
        affiliate.update_columns(affiliate_basis_points: 3000 + 100 * idx, updated_at: Time.now)
      end
      ProductAffiliate.where(affiliate_id: affiliate_user_2.id).each.with_index do |affiliate, idx|
        affiliate.update_columns(affiliate_basis_points: 2000 + 100 * idx, updated_at: Time.now + 1)
      end
      ProductAffiliate.where(affiliate_id: affiliate_user_3.id).each.with_index do |affiliate, idx|
        affiliate.update_columns(affiliate_basis_points: 1000 + 100 * idx, updated_at: Time.now + 2)
      end
      ProductAffiliate.where(affiliate_id: affiliate_user_4.id).each.with_index do |affiliate, idx|
        affiliate.update_columns(affiliate_basis_points: 100 + 100 * idx, updated_at: Time.now + 3)
      end

      create_list(:purchase_with_balance, 2, link: product1, affiliate: affiliate_user_1)
      create_list(:purchase_with_balance, 3, link: product1, affiliate: affiliate_user_2)
      create(:purchase_with_balance, link: product1, affiliate: affiliate_user_3)
      create_list(:purchase_with_balance, 2, link: product1, affiliate: affiliate_user_4)

      # Properly test sorting on affiliate_user_name
      affiliate_user_1.affiliate_user.update_columns(name: "alice", username: nil, unconfirmed_email: "ignored@example.com", email: "ignored@example.com")
      affiliate_user_2.affiliate_user.update_columns(name: nil, username: "bob", unconfirmed_email: "ignored@example.com", email: "ignored@example.com")
      affiliate_user_3.affiliate_user.update_columns(name: nil, username: nil, unconfirmed_email: "david@example.com", email: "ignored@example.com")
      affiliate_user_4.affiliate_user.update_columns(name: nil, username: nil, unconfirmed_email: nil, email: "charlie@example.com")

      sign_in seller
    end

    it "sorts the affiliates" do
      visit affiliates_path
      current_affiliates_table = find("caption", text: "Affiliates").find(:xpath, "..")

      within current_affiliates_table do
        find(:columnheader, "Name").click
      end

      expect(page).to have_table_row({ "Name" => "alice", "Products" => "p1", "Commission" => "30%", "Sales" => "$2" })
      expect(page).to have_current_path("#{affiliates_path}?page=1&column=affiliate_user_name&sort=asc")
      expect(page).to have_table "Requests", with_rows: [{ "Name" => affiliate_request.name }]

      within current_affiliates_table do
        find(:columnheader, "Name").click
      end

      expect(page).to have_table_row({ "Name" => "david@example.com", "Products" => "2 products", "Commission" => "10% - 11%", "Sales" => "$1" })
      expect(page).to have_current_path("#{affiliates_path}?page=1&column=affiliate_user_name&sort=desc")
      expect(page).to have_table "Requests", with_rows: [{ "Name" => affiliate_request.name }]

      within current_affiliates_table do
        find(:columnheader, "Products").click
      end

      expect(page).to have_table_row({ "Name" => "alice", "Products" => "p1", "Commission" => "30%", "Sales" => "$2" })
      expect(page).to have_current_path("#{affiliates_path}?page=1&column=products&sort=asc")
      expect(page).to have_table "Requests", with_rows: [{ "Name" => affiliate_request.name }]

      within current_affiliates_table do
        find(:columnheader, "Products").click
      end

      expect(page).to have_table_row({ "Name" => "charlie@example.com", "Products" => "4 products", "Commission" => "1% - 4%", "Sales" => "$2" })
      expect(page).to have_current_path("#{affiliates_path}?page=1&column=products&sort=desc")
      expect(page).to have_table "Requests", with_rows: [{ "Name" => affiliate_request.name }]

      within current_affiliates_table do
        find(:columnheader, "Commission").click
      end

      expect(page).to have_table_row({ "Name" => "charlie@example.com", "Products" => "4 products", "Commission" => "1% - 4%", "Sales" => "$2" })
      expect(page).to have_current_path("#{affiliates_path}?page=1&column=fee_percent&sort=asc")
      expect(page).to have_table "Requests", with_rows: [{ "Name" => affiliate_request.name }]

      within current_affiliates_table do
        find(:columnheader, "Commission").click
      end

      expect(page).to have_table_row({ "Name" => "alice", "Products" => "p1", "Commission" => "30%", "Sales" => "$2" })
      expect(page).to have_current_path("#{affiliates_path}?page=1&column=fee_percent&sort=desc")
      expect(page).to have_table "Requests", with_rows: [{ "Name" => affiliate_request.name }]

      within current_affiliates_table do
        find(:columnheader, "Sales").click
      end

      expect(page).to have_table_row({ "Name" => "david@example.com", "Products" => "2 products", "Commission" => "10% - 11%", "Sales" => "$1" })
      expect(page).to have_current_path("#{affiliates_path}?page=1&column=volume_cents&sort=asc")
      expect(page).to have_table "Requests", with_rows: [{ "Name" => affiliate_request.name }]

      within current_affiliates_table do
        find(:columnheader, "Sales").click
      end

      expect(page).to have_table_row({ "Name" => "bob", "Products" => "3 products", "Commission" => "20% - 22%", "Sales" => "$3" })
      expect(page).to have_table "Requests", with_rows: [{ "Name" => affiliate_request.name }]
      expect(page).to have_current_path("#{affiliates_path}?page=1&column=volume_cents&sort=desc")
    end

    it "sets the page to 1 on sort" do
      visit affiliates_path
      current_affiliates_table = find("caption", text: "Affiliates").find(:xpath, "..")

      within find("[aria-label='Pagination']") do
        expect(find_button("1")["aria-current"]).to eq("page")
        click_on "2"
        wait_for_ajax

        expect(find_button("1")["aria-current"]).to be_nil
        expect(find_button("2")["aria-current"]).to eq("page")
        expect(page).to have_current_path(affiliates_path({ page: "2" }))
      end

      within current_affiliates_table do
        find(:columnheader, "Name").click
      end
      wait_for_ajax

      within find("[aria-label='Pagination']") do
        expect(find_button("1")["aria-current"]).to eq("page")
        expect(find_button("2")["aria-current"]).to be_nil
        expect(page).to have_current_path("#{affiliates_path}?page=1&column=affiliate_user_name&sort=asc")
      end
    end

    it "handles browser events for going to the previous/next page" do
      visit affiliates_path
      current_affiliates_table = find("caption", text: "Affiliates").find(:xpath, "..")

      within current_affiliates_table do
        find(:columnheader, "Name").click
      end
      wait_for_ajax
      page.go_back
      wait_for_ajax

      expect(page).to have_current_path(affiliates_path)
      expect(page).to have_table_row({ "Name" => "charlie@example.com", "Products" => "4 products", "Commission" => "1% - 4%", "Sales" => "$2" })
      expect(page).to have_table "Requests", with_rows: [{ "Name" => affiliate_request.name }]

      page.go_forward
      wait_for_ajax

      expect(page).to have_current_path("#{affiliates_path}?page=1&column=affiliate_user_name&sort=asc")
      expect(page).to have_table_row({ "Name" => "alice", "Products" => "p1", "Commission" => "30%", "Sales" => "$2" })

      within find("[aria-label='Pagination']") do
        expect(find_button("1")["aria-current"]).to eq("page")

        click_on "2"
        wait_for_ajax

        expect(find_button("1")["aria-current"]).to be_nil
        expect(find_button("2")["aria-current"]).to eq("page")

        page.go_back
        wait_for_ajax

        expect(find_button("1")["aria-current"]).to eq("page")
        expect(find_button("2")["aria-current"]).to be_nil
        expect(page).to have_current_path("#{affiliates_path}?page=1&column=affiliate_user_name&sort=asc")

        page.go_forward
        wait_for_ajax

        expect(find_button("1")["aria-current"]).to be_nil
        expect(find_button("2")["aria-current"]).to eq("page")
        expect(page).to have_current_path("#{affiliates_path}?page=2&column=affiliate_user_name&sort=asc")
      end
    end
  end

  context "New Password page" do
    it "allows access to all settings" do
      direct_affiliate = create(:affiliate_user)
      login_as direct_affiliate
      visit settings_password_path

      menu_items = all("a[role='tab']")
      expected_items = %w[Settings Payments Password Advanced]
      expect(menu_items.collect(&:text)).to include(*expected_items)
    end
  end
end
