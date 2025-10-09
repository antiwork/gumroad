# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/creator_dashboard_page"

describe("Checkout discounts page", type: :system, js: true) do
  include CurrencyHelper

  let(:seller) { create(:named_seller) }
  let(:product1) { create(:product, name: "Product 1", user: seller, price_cents: 1000, price_currency_type: Currency::EUR) }
  let(:product2) { create(:product, name: "Product 2", user: seller, price_cents: 500) }
  let(:membership) { create(:membership_product_with_preset_tiered_pricing, name: "Membership", user: seller) }
  let!(:offer_code1) { create(:percentage_offer_code, name: "Discount 1", code: "code1", products: [product1, product2, membership], user: seller, max_purchase_count: 12, valid_at: ActiveSupport::TimeZone[seller.timezone].parse("January 1 #{Time.current.year - 1}"), expires_at: ActiveSupport::TimeZone[seller.timezone].parse("February 1 #{Time.current.year - 1}"), minimum_quantity: 5, duration_in_billing_cycles: 1, minimum_amount_cents: 1000) }
  let!(:offer_code2) { create(:offer_code, name: "Discount 2", code: "code2", products: [product2], user: seller, max_purchase_count: 20, amount_cents: 200, valid_at: ActiveSupport::TimeZone[seller.timezone].parse("January 1 #{Time.current.year + 1}")) }
  let!(:offer_code3) { create(:percentage_offer_code, name: "Discount 3", code: "code3", universal: true, products: [], user: seller, amount_percentage: 50) }

  before do
    create_list(:purchase, 10, link: product1, offer_code: offer_code1, displayed_price_currency_type: Currency::EUR, price_cents: get_usd_cents(Currency::EUR, product1.price_cents))
    create_list(:purchase, 5, link: product2, offer_code: offer_code2)
    create(:purchase, link: product1, offer_code: offer_code3)
    create(:purchase, link: product2, offer_code: offer_code3)
  end

  include_context "with switching account to user as admin for seller"

  it_behaves_like "creator dashboard page", "Checkout" do
    let(:path) { checkout_discounts_path }
  end

  describe "discounts table" do
    before do
      offer_code1.products += build_list(:product, 2, user: seller, price_cents: 1000) do |product, i|
        product.update!(name: "Product #{i + 3}")
      end
    end

    it "displays all offer codes correctly" do
      visit checkout_discounts_path
      within find(:table_row, { "Discount" => "Discount 1", "Revenue" => "$123.30", "Uses" => "10/12", "Term" => "Jan 1, #{Time.current.year - 1} - Feb 1, #{Time.current.year - 1}", "Status" => "Expired" }) do
        expect(page).to have_text("50% off of Product 1, Product 2, and 3 others")
        expect(page).to have_selector("[aria-label='Offer code']", text: "CODE1")
      end
      within find(:table_row, { "Discount" => "Discount 2", "Revenue" => "$25", "Uses" => "5/20", "Term" => "Jan 1, #{Time.current.year + 1} - No end date", "Status" => "Scheduled" }) do
        expect(page).to have_text("$2 off of Product 2")
        expect(page).to have_selector("[aria-label='Offer code']", text: "CODE2")
      end

      within find(:table_row, { "Discount" => "Discount 3", "Revenue" => "$15", "Uses" => "2/∞", "Term" => "No end date", "Status" => "Live" }) do
        expect(page).to have_text("50% off of all products")
        expect(page).to have_selector("[aria-label='Offer code']", text: "CODE3")
      end
    end

    it "displays offer code drawers" do
      visit checkout_discounts_path
      find(:table_row, { "Discount" => "Discount 1" }).click
      within_section "Discount 1", section_element: :aside do
        within_section "Details" do
          expect(page).to have_text("Code CODE1", normalize_ws: true)
          expect(page).to have_text("Discount 50%", normalize_ws: true)
          expect(page).to have_text("Uses 10/12", normalize_ws: true)
          expect(page).to have_text("Revenue $123.30", normalize_ws: true)
          expect(page).to have_text("Start date Jan 1, #{Time.current.year - 1}, 12 AM", normalize_ws: true)
          expect(page).to have_text("End date Feb 1, #{Time.current.year - 1}, 12 AM", normalize_ws: true)
          expect(page).to have_text("Minimum quantity 5", normalize_ws: true)
          expect(page).to have_text("Discount duration for memberships Once (first billing period only)", normalize_ws: true)
          expect(page).to have_text("Minimum amount $10", normalize_ws: true)
        end

        within_section "Products" do
          expect(page).to have_text("Product 1 10 uses", normalize_ws: true)
          expect(page).to have_text("Product 2 0 uses", normalize_ws: true)
          expect(page).to have_text("Product 3 0 uses", normalize_ws: true)
          expect(page).to have_text("Product 4 0 uses", normalize_ws: true)
          expect(page).to have_button("Copy link", count: 5)
        end

        expect(page).to have_button("Duplicate")
        expect(page).to have_button("Edit")
        expect(page).to have_button("Delete")
      end

      find(:table_row, { "Discount" => "Discount 2" }).click
      within_section "Discount 2", section_element: :aside do
        within_section "Details" do
          expect(page).to have_text("Code CODE2", normalize_ws: true)
          expect(page).to have_text("Discount $2", normalize_ws: true)
          expect(page).to have_text("Uses 5/20", normalize_ws: true)
          expect(page).to have_text("Revenue $25", normalize_ws: true)
          expect(page).to have_text("Start date Jan 1, #{Time.current.year + 1}, 12 AM", normalize_ws: true)
          expect(page).to_not have_text("End date")
          expect(page).to_not have_text("Minimum quantity")
          expect(page).to_not have_text("Discount duration for memberships")
          expect(page).to_not have_text("Minimum amount")
        end

        within_section "Products" do
          expect(page).to have_text("Product 2 5 uses", normalize_ws: true)
          expect(page).to have_button("Copy link")
        end

        expect(page).to have_button("Duplicate")
        expect(page).to have_button("Edit")
        expect(page).to have_button("Delete")
      end

      find(:table_row, { "Discount" => "Discount 3" }).click
      within_section "Discount 3", section_element: :aside do
        within_section "Details" do
          expect(page).to have_text("Code CODE3", normalize_ws: true)
          expect(page).to have_text("Discount 50%", normalize_ws: true)
          expect(page).to have_text("Uses 2/∞", normalize_ws: true)
          expect(page).to have_text("Revenue $15", normalize_ws: true)
          expect(page).to have_text("Discount duration for memberships Forever", normalize_ws: true)
          expect(page).to_not have_text("Start date")
          expect(page).to_not have_text("End date")
          expect(page).to_not have_text("Minimum quantity")
          expect(page).to_not have_text("Minimum amount")
        end

        expect(page).to_not have_section("Products")

        expect(page).to have_button("Duplicate")
        expect(page).to have_button("Edit")
        expect(page).to have_button("Delete")
      end
    end

    context "when the creator has no discounts" do
      it "displays a placeholder message" do
        login_as create(:user)
        visit checkout_discounts_path

        expect(page).to have_text("No discounts yet")
        expect(page).to have_text("Use discounts to create sweet deals for your customers")
      end
    end
  end

  describe "creating offer codes" do
    describe "percentage offer code" do
      it "creates the offer code" do
        visit checkout_discounts_path
        click_on "New discount"

        fill_in "Name", with: "Black Friday"
        code = find_field("Discount code").value
        click_on "Generate new discount"
        new_code = find_field("Discount code").value
        expect(new_code).to_not eq(code)
        check "All products"
        fill_in "Percentage", with: "10"
        check "Limit quantity"
        fill_in "Quantity", with: "10"

        check "Limit validity period"
        fill_in_datetime "Valid from", with: "2022-11-02T23:00"

        check "Set a minimum quantity"
        fill_in "Minimum quantity per product", with: "1"

        select "Once (first billing period only)", from: "Discount duration for memberships"

        check "Set a minimum qualifying amount"
        fill_in "Minimum amount", with: "10"

        click_on "Add discount"

        expect(page).to have_alert(text: "Successfully created discount!")

        within find(:table_row, { "Discount" => "Black Friday", "Revenue" => "$0", "Uses" => "0/10" }) do
          expect(page).to have_text("10% off of all products")
          expect(page).to have_selector("[aria-label='Offer code']", text: new_code.upcase)
        end

        visit checkout_discounts_path
        within find(:table_row, { "Discount" => "Black Friday", "Revenue" => "$0", "Uses" => "0/10" }) do
          expect(page).to have_text("10% off of all products")
          expect(page).to have_selector("[aria-label='Offer code']", text: new_code.upcase)
        end

        offer_code = OfferCode.last
        expect(offer_code.name).to eq("Black Friday")
        expect(offer_code.code).to eq(new_code)
        expect(offer_code.currency_type).to eq(nil)
        expect(offer_code.amount_percentage).to eq(10)
        expect(offer_code.amount_cents).to eq(nil)
        expect(offer_code.max_purchase_count).to eq(10)
        expect(offer_code.universal).to eq(true)
        expect(offer_code.valid_at).to eq(ActiveSupport::TimeZone[seller.timezone].local(2022, 11, 2, 23))
        expect(offer_code.expires_at).to eq(nil)
        expect(offer_code.minimum_quantity).to eq(1)
        expect(offer_code.duration_in_billing_cycles).to eq(1)
        expect(offer_code.minimum_amount_cents).to eq(1000)
      end

      context "when the selected products have different currency types" do
        it "doesn't allow switching to fixed amount" do
          create(:product, name: "Product 3", user: seller, price_currency_type: "gbp")
          visit checkout_discounts_path
          click_on "New discount"

          find(:label, "Products").click
          select_combo_box_option "Product 1", from: "Products"
          select_combo_box_option "Product 3", from: "Products"

          fixed_amount_field = find_field("Fixed amount", disabled: true, match: :first)
          fixed_amount_field.hover
          expect(fixed_amount_field).to have_tooltip(text: "To select a fixed amount, make sure the selected products are priced in the same currency.")
        end
      end

      context "when a product is archived" do
        before { product1.update!(archived: true) }

        it "doens't include the product in the product list" do
          visit checkout_discounts_path
          click_on "New discount"

          find(:label, "Products").click
          expect(page).to have_combo_box "Products", options: ["Product 2", "Membership"]
        end
      end
    end

    describe "absolute offer code" do
      it "creates the offer code" do
        visit checkout_discounts_path
        click_on "New discount"

        fill_in "Name", with: "Black Friday"
        code = "code"
        fill_in "Discount code", with: code
        check "All products"
        choose "Fixed amount"
        fill_in "Fixed amount", with: "10"

        check "Limit validity period"
        fill_in_datetime "Valid from", with: "2022-11-02T23:00"

        uncheck "No end date"
        fill_in_datetime "Valid until", with: "2022-12-02T23:00"

        click_on "Add discount"

        expect(page).to have_alert(text: "Successfully created discount!")

        within find(:table_row, { "Discount" => "Black Friday", "Revenue" => "$0", "Uses" => "0/∞" }) do
          expect(page).to have_text("€10 off of all products")
          expect(page).to have_selector("[aria-label='Offer code']", text: code.upcase)
        end

        visit checkout_discounts_path
        within find(:table_row, { "Discount" => "Black Friday", "Revenue" => "$0", "Uses" => "0/∞" }) do
          expect(page).to have_text("€10 off of all products")
          expect(page).to have_selector("[aria-label='Offer code']", text: code.upcase)
        end

        offer_code = OfferCode.last
        expect(offer_code.name).to eq("Black Friday")
        expect(offer_code.code).to eq(code)
        expect(offer_code.currency_type).to eq("eur")
        expect(offer_code.amount_cents).to eq(1000)
        expect(offer_code.amount_percentage).to eq(nil)
        expect(offer_code.max_purchase_count).to eq(nil)
        expect(offer_code.universal).to eq(true)
        expect(offer_code.valid_at).to eq(ActiveSupport::TimeZone[seller.timezone].local(2022, 11, 2, 23))
        expect(offer_code.expires_at).to eq(ActiveSupport::TimeZone[seller.timezone].local(2022, 12, 2, 23))
        expect(offer_code.minimum_quantity).to eq(nil)
        expect(offer_code.duration_in_billing_cycles).to eq(nil)
        expect(offer_code.minimum_amount_cents).to eq(nil)
      end

      context "when the offer code has multiple products" do
        it "creates the offer code" do
          visit checkout_discounts_path

          click_on "New discount"

          fill_in "Name", with: "Black Friday"
          code = "code"
          fill_in "Discount code", with: code
          fill_in "Percentage", with: "10"

          select_combo_box_option search: "Product 1", from: "Products"
          select_combo_box_option search: "Product 2", from: "Products"

          click_on "Add discount"

          within find(:table_row, { "Discount" => "Black Friday", "Revenue" => "$0", "Uses" => "0/∞" }) do
            expect(page).to have_text("10% off of Product 1, Product 2")
            expect(page).to have_selector("[aria-label='Offer code']", text: code.upcase)
          end

          expect(page).to have_section("Black Friday", section_element: :aside)

          visit checkout_discounts_path
          within find(:table_row, { "Discount" => "Black Friday", "Revenue" => "$0", "Uses" => "0/∞" }) do
            expect(page).to have_text("10% off of Product 1, Product 2")
            expect(page).to have_selector("[aria-label='Offer code']", text: code.upcase)
          end

          offer_code = OfferCode.last
          expect(offer_code.name).to eq("Black Friday")
          expect(offer_code.code).to eq(code)
          expect(offer_code.currency_type).to eq(nil)
          expect(offer_code.amount_percentage).to eq(10)
          expect(offer_code.amount_cents).to eq(nil)
          expect(offer_code.max_purchase_count).to eq(nil)
          expect(offer_code.universal).to eq(false)
          expect(offer_code.products).to eq([product1, product2])
          expect(offer_code.valid_at).to eq(nil)
          expect(offer_code.expires_at).to eq(nil)
          expect(offer_code.minimum_quantity).to eq(nil)
          expect(offer_code.duration_in_billing_cycles).to eq(nil)
          expect(offer_code.minimum_amount_cents).to eq(nil)
        end

        it "only allows the selection of products with the same currency" do
          create(:product, name: "Product 3", user: seller, price_currency_type: "gbp")
          visit checkout_discounts_path

          click_on "New discount"

          choose "Fixed amount"

          find(:label, "Products").click
          expect(page).to have_combo_box "Products", options: ["Product 1", "Product 2", "Membership", "Product 3"]
          select_combo_box_option "Product 1", from: "Products"
          find(:label, "Products").click
          expect(page).to have_combo_box "Products", options: ["Product 2", "Membership", "Product 3"]

          click_on "Product 1"
          select_combo_box_option "Product 3", from: "Products"
          find(:label, "Products").click
          expect(page).to have_combo_box "Products", options: ["Product 1", "Membership"]
        end
      end

      context "when the offer code is universal" do
        it "allows the selection of a currency type" do
          create(:product, name: "Product 3", user: seller, price_currency_type: "gbp")
          visit checkout_discounts_path

          click_on "New discount"
          fill_in "Name", with: "Discount"
          check "All products"
          choose "Fixed amount"
          select "£", from: "Currency", visible: false
          fill_in "Fixed amount", with: "1"
          click_on "Add discount"

          expect(page).to have_alert(text: "Successfully created discount!")

          within_section "Discount", section_element: :aside do
            click_on "Edit"
          end
          expect(page).to have_select("Currency", selected: "£", visible: false)

          expect(OfferCode.last.currency_type).to eq("gbp")
        end
      end

      context "when the offer code's code is taken" do
        before do
          create(:offer_code, user: seller, code: "code")
        end

        it "displays an error message" do
          visit checkout_discounts_path

          click_on "New discount"

          fill_in "Name", with: "Black Friday"
          check "All products"
          fill_in "Percentage", with: "100"
          fill_in "Discount code", with: "code"

          click_on "Add discount"

          expect(page).to have_alert(text: "Discount code must be unique.")
        end
      end

      context "when required fields aren't filled" do
        it "displays error statuses" do
          visit checkout_discounts_path

          click_on "New discount"
          fill_in "Discount code", with: ""
          fill_in "Percentage", with: ""

          click_on "Add discount"
          expect(find_field("Name")["aria-invalid"]).to eq("true")
          expect(find_field("Discount code")["aria-invalid"]).to eq("true")
          expect(find_field("Percentage", type: "text")["aria-invalid"]).to eq("true")
        end
      end

      context "when the offer code would discount the product below its currency's minimum but above 0" do
        it "displays an error message" do
          visit checkout_discounts_path

          click_on "New discount"

          fill_in "Name", with: "Black Friday"
          choose "Fixed amount"
          fill_in "Fixed amount", with: "9.50"

          select_combo_box_option search: "Product 1", from: "Products"

          click_on "Add discount"

          expect(page).to have_alert(text: "The price after discount for all of your products must be either €0 or at least €0.79.")
        end
      end

      context "when the offer code's expiration date is before its validity date" do
        it "displays an error status" do
          visit checkout_discounts_path

          click_on "New discount"
          check "Limit validity period"
          fill_in_datetime "Valid from", with: "2022-12-02T23:00"

          uncheck "No end date"
          fill_in_datetime "Valid until", with: "2022-11-02T23:00"

          click_on "Add discount"
          expect(find_field("Valid until")["aria-invalid"]).to eq("true")
        end
      end
    end

    context "when the offer code applies to a membership" do
      it "displays the duration select" do
        visit checkout_discounts_path

        click_on "New discount"

        check "All products"
        expect(page).to have_select("Discount duration for memberships", options: ["Once (first billing period only)", "Forever"], selected: "Forever")

        uncheck "All products"
        expect(page).to_not have_select("Discount duration for memberships")

        find(:label, "Products").click
        select_combo_box_option "Membership", from: "Products"
        expect(page).to have_select("Discount duration for memberships", options: ["Once (first billing period only)", "Forever"], selected: "Forever")
      end
    end
  end

  describe "editing offer codes" do
    it "updates the offer code" do
      # Allows us to test editing an offer code that already has `valid_at`
      # set with fewer date picker interactions
      offer_code2.update!(valid_at: Time.current)

      visit checkout_discounts_path

      table_row = find(:table_row, { "Discount" => "Discount 2" })
      within table_row do
        click_on "Edit"
      end
      expect(page).to have_section("Edit discount")
      click_on "Cancel"

      table_row.click
      within_section "Discount 2", section_element: :aside do
        click_on "Edit"
      end

      expect(page).to have_field("Name", with: "Discount 2")
      expect(page).to have_field("Discount code", with: "code2")
      expect(page).to have_checked_field("Fixed amount")
      expect(page).to have_field("Fixed amount", with: "2")
      expect(page).to have_unchecked_field("All products")
      find("label", text: "Products").click
      expect(page).to have_combo_box("Products", options: ["Membership"])
      expect(page).to have_checked_field("Limit quantity")
      expect(page).to have_field("Quantity", with: "20")
      expect(page).to have_field("Valid from", with: offer_code2.valid_at.in_time_zone(seller.timezone).iso8601[0..15])
      expect(page).to have_checked_field("No end date")
      expect(page).to_not have_select("Discount duration for memberships")

      fill_in "Name", with: "Black Friday"

      check "All products"
      choose "Percentage"
      fill_in "Percentage", with: "10"
      check "Limit quantity"
      fill_in "Quantity", with: "10"

      check "Set a minimum qualifying amount"
      fill_in "Minimum amount", with: "5"
      fill_in_datetime "Valid from", with: "2022-11-02T23:00"

      uncheck "No end date"
      fill_in_datetime "Valid until", with: "2022-12-02T23:00"

      click_on "Save changes"

      expect(page).to have_alert(text: "Successfully updated discount!")

      within find(:table_row, { "Discount" => "Black Friday", "Revenue" => "$25", "Uses" => "5/10" }) do
        expect(page).to have_text("10% off of all products")
        expect(page).to have_selector("[aria-label='Offer code']", text: "CODE2")
      end

      visit checkout_discounts_path
      within find(:table_row, { "Discount" => "Black Friday", "Revenue" => "$25", "Uses" => "5/10" }) do
        expect(page).to have_text("10% off of all products")
        expect(page).to have_selector("[aria-label='Offer code']", text: "CODE2")
      end

      offer_code2.reload
      expect(offer_code2.name).to eq("Black Friday")
      expect(offer_code2.code).to eq("code2")
      expect(offer_code2.currency_type).to eq(nil)
      expect(offer_code2.amount_percentage).to eq(10)
      expect(offer_code2.amount_cents).to eq(nil)
      expect(offer_code2.max_purchase_count).to eq(10)
      expect(offer_code2.universal).to eq(true)
      expect(offer_code2.valid_at).to eq(ActiveSupport::TimeZone[seller.timezone].local(2022, 11, 2, 23))
      expect(offer_code2.expires_at).to eq(ActiveSupport::TimeZone[seller.timezone].local(2022, 12, 2, 23))
      expect(offer_code2.duration_in_billing_cycles).to eq(nil)
      expect(offer_code2.minimum_amount_cents).to eq(500)
    end

    context "when the offer code has multiple products" do
      let!(:product3) { create(:product, name: "Product 3", user: seller, price_cents: 2000) }

      it "updates the offer code" do
        visit checkout_discounts_path

        find(:table_row, { "Discount" => "Discount 1" }).click
        within_section "Discount 1", section_element: :aside do
          click_on "Edit"
        end

        fill_in "Name", with: "Black Friday"
        choose "Percentage"
        fill_in "Percentage", with: "10"

        click_on "Product 2"
        select_combo_box_option search: "Product 3", from: "Products"

        uncheck "Limit quantity"
        uncheck "Limit validity period"
        uncheck "Set a minimum qualifying amount"

        expect(page).to have_checked_field("Set a minimum quantity")
        expect(page).to have_field("Minimum quantity per product", with: "5")
        uncheck "Set a minimum quantity"

        expect(page).to have_select("Discount duration for memberships", options: ["Once (first billing period only)", "Forever"], selected: "Once (first billing period only)")
        select "Forever", from: "Discount duration for memberships"

        click_on "Save changes"

        within find(:table_row, { "Discount" => "Black Friday", "Revenue" => "$123.30", "Uses" => "10/∞" }) do
          expect(page).to have_text("10% off of Product 1, Membership, and 1 other")
          expect(page).to have_selector("[aria-label='Offer code']", text: "CODE1")
        end

        expect(page).to have_section("Black Friday", section_element: :aside)

        visit checkout_discounts_path
        within find(:table_row, { "Discount" => "Black Friday", "Revenue" => "$123.30", "Uses" => "10/∞" }) do
          expect(page).to have_text("10% off of Product 1, Membership, and 1 other")
          expect(page).to have_selector("[aria-label='Offer code']", text: "CODE1")
        end

        offer_code1.reload
        expect(offer_code1.name).to eq("Black Friday")
        expect(offer_code1.code).to eq("code1")
        expect(offer_code1.currency_type).to eq(nil)
        expect(offer_code1.amount_percentage).to eq(10)
        expect(offer_code1.amount_cents).to eq(nil)
        expect(offer_code1.max_purchase_count).to eq(nil)
        expect(offer_code1.universal).to eq(false)
        expect(offer_code1.products).to eq([product1, membership, product3])
        expect(offer_code1.valid_at).to eq(nil)
        expect(offer_code1.expires_at).to eq(nil)
        expect(offer_code1.minimum_quantity).to eq(nil)
        expect(offer_code1.duration_in_billing_cycles).to eq(nil)
        expect(offer_code1.minimum_amount_cents).to eq(nil)
      end
    end

    context "when required fields aren't filled" do
      it "displays error statuses" do
        visit checkout_discounts_path

        find(:table_row, { "Discount" => "Discount 1" }).click
        within_section "Discount 1", section_element: :aside do
          click_on "Edit"
        end

        fill_in "Name", with: ""
        within find(:fieldset, "Products") do
          click_on "Clear value"
        end
        fill_in "Percentage", with: ""
        fill_in "Quantity", with: ""
        fill_in "Minimum quantity per product", with: ""
        fill_in "Minimum amount", with: ""

        click_on "Save changes"
        expect(find_field("Name")["aria-invalid"]).to eq("true")
        expect(find_field("Percentage", type: "text")["aria-invalid"]).to eq("true")
        expect(find_field("Products")["aria-invalid"]).to eq("true")
        expect(find_field("All products")["aria-invalid"]).to eq("true")
        expect(find_field("Quantity")["aria-invalid"]).to eq("true")
        expect(find_field("Minimum quantity per product")["aria-invalid"]).to eq("true")
        expect(find_field("Minimum amount")["aria-invalid"]).to eq("true")
      end
    end

    context "when the offer code would discount the product below its currency's minimum but above 0" do
      it "displays an error message" do
        visit checkout_discounts_path

        find(:table_row, { "Discount" => "Discount 1" }).click
        within_section "Discount 1", section_element: :aside do
          click_on "Edit"
        end

        fill_in "Name", with: "Black Friday"
        choose "Percentage"
        fill_in "Percentage", with: "95"

        click_on "Save changes"

        expect(page).to have_alert(text: "The price after discount for all of your products must be either €0 or at least €0.79.")
      end
    end

    context "when a selected product is archived" do
      before do
        product1.update!(archived: true)
      end

      it "preserves the archived product on save" do
        visit checkout_discounts_path

        find(:table_row, { "Discount" => "Discount 1" }).click
        within_section "Discount 1", section_element: :aside do
          click_on "Edit"
        end

        find(:label, "Products").click
        expect(page).to have_combo_box "Products", options: ["Product 1", "Product 2", "Membership"]

        click_on "Save changes"

        expect(offer_code1.reload.products).to eq([product1, product2, membership])
      end
    end
  end

  it "deletes the offer code" do
    visit checkout_discounts_path

    within find(:table_row, { "Discount" => "Discount 1" }) do
      select_disclosure "Open discount action menu"  do
        click_on "Delete"
      end
    end
    expect(page).to have_alert(text: "Successfully deleted discount!")
    expect(page).to_not have_selector(:table_row, { "Discount" => "Discount 1" })

    find(:table_row, { "Discount" => "Discount 2" }).click
    within_section "Discount 2", section_element: :aside do
      click_on "Delete"
    end
    expect(page).to have_alert(text: "Successfully deleted discount!")
    expect(page).to_not have_selector(:table_row, { "Discount" => "Discount 2" })

    visit checkout_discounts_path
    expect(page).to_not have_selector(:table_row, { "Discount" => "Discount 1" })
    expect(page).to_not have_selector(:table_row, { "Discount" => "Discount 2" })

    expect(offer_code1.reload.deleted_at).to be_present
    expect(offer_code2.reload.deleted_at).to be_present
  end

  it "duplicates the offer code" do
    visit checkout_discounts_path

    table_row = find(:table_row, { "Discount" => "Discount 1" })
    within table_row do
      select_disclosure "Open discount action menu" do
        click_on "Duplicate"
      end
    end

    expect(page).to have_section("Create discount")
    click_on "Cancel"

    table_row.click
    within_section "Discount 1", section_element: :aside do
      click_on "Duplicate"
    end

    code = find_field("Discount code").value

    expect(page).to have_section("Create discount")
    expect(page).to have_field("Name", with: "Discount 1")
    expect(page).to have_checked_field("Percentage")
    expect(page).to have_field("Percentage", with: "50")
    expect(page).to have_unchecked_field("All products")
    find("label", text: "Products").click
    expect(page).to have_combo_box("Products", options: ["Product 1", "Product 2"])
    find("body").native.send_key("escape") # to dismiss the combo box so the limit quantity checkbox is visible
    expect(page).to have_checked_field("Limit quantity")
    expect(page).to have_field("Quantity", with: "12")
    expect(page).to have_field("Valid from", with: "#{Time.current.year - 1}-01-01T00:00")
    expect(page).to have_unchecked_field("No end date")
    expect(page).to have_field("Valid until", with: "#{Time.current.year - 1}-02-01T00:00")
    expect(page).to have_checked_field("Set a minimum quantity")
    expect(page).to have_field("Minimum quantity per product", with: "5")
    expect(page).to have_checked_field("Set a minimum qualifying amount")
    expect(page).to have_field("Minimum amount", with: "10")

    check "Limit quantity"
    fill_in "Quantity", with: "5"
    fill_in "Name", with: "Discount 1 Duplicate"

    click_on "Add discount"

    expect(page).to have_alert(text: "Successfully created discount!")
    expect(page).to have_selector(:table_row, { "Discount" => "Discount 1 Duplicate" })

    offer_code = OfferCode.last
    expect(offer_code.name).to eq("Discount 1 Duplicate")
    expect(offer_code.code).to eq(code)
    expect(offer_code.currency_type).to eq(nil)
    expect(offer_code.amount_percentage).to eq(50)
    expect(offer_code.amount_cents).to eq(nil)
    expect(offer_code.max_purchase_count).to eq(5)
    expect(offer_code.universal).to eq(false)
    expect(offer_code.products).to eq([product1, product2, membership])
    expect(offer_code.valid_at).to eq(offer_code1.valid_at)
    expect(offer_code.expires_at).to eq(offer_code1.expires_at)
  end

  describe "pagination" do
    before do
      stub_const("Checkout::DiscountsController::PER_PAGE", 1)
    end

    it "paginates the offer codes" do
      visit checkout_discounts_path
      expect(page).to have_button("Previous", disabled: true)
      expect(page).to have_button("Next")
      expect(page).to have_selector(:table_row, { "Discount" => "Discount 1" })

      click_on "2"

      expect(page).to have_button("Previous")
      expect(page).to have_button("Next")
      expect(page).to have_current_path(checkout_discounts_path({ page: 2 }))

      expect(page).to have_selector(:table_row, { "Discount" => "Discount 2" })

      click_on "3"

      expect(page).to have_button("Previous")
      expect(page).to have_button("Next", disabled: true)
      expect(page).to have_current_path(checkout_discounts_path({ page: 3 }))

      expect(page).to have_selector(:table_row, { "Discount" => "Discount 3" })
    end
  end

  describe "sorting" do
    before do
      build_list(:offer_code, 3, user: seller, universal: true) do |offer_code, i|
        offer_code.update!(name: "Discount #{i + 3}", code: "discount#{i + 3}", valid_at: i.days.ago, updated_at: i.days.ago)
      end
      stub_const("Checkout::DiscountsController::PER_PAGE", 2)
    end

    it "sorts the offer codes" do
      visit checkout_discounts_path
      find(:columnheader, "Discount").click
      expect(page).to have_nth_table_row_record(1, "CODE1Discount 1 50% off of Product 1, Product 2, and 1 other")
      expect(page).to have_nth_table_row_record(2, "CODE2Discount 2 $2 off of Product 2")
      expect(page).to have_current_path(checkout_discounts_path({ column: "name", page: 1, sort: "asc" }))
      find(:columnheader, "Discount").click
      expect(page).to have_nth_table_row_record(1, "DISCOUNT5Discount 5 $1 off of all products")
      expect(page).to have_nth_table_row_record(2, "DISCOUNT4Discount 4 $1 off of all products")
      expect(page).to have_current_path(checkout_discounts_path({ column: "name", page: 1, sort: "desc" }))
      find(:columnheader, "Revenue").click
      expect(page).to have_nth_table_row_record(1, "DISCOUNT3Discount 3 $1 off of all products")
      expect(page).to have_nth_table_row_record(2, "DISCOUNT4Discount 4 $1 off of all products")
      expect(page).to have_current_path(checkout_discounts_path({ column: "revenue", page: 1, sort: "asc" }))
      find(:columnheader, "Revenue").click
      expect(page).to have_nth_table_row_record(1, "CODE1Discount 1 50% off of Product 1, Product 2, and 1 other")
      expect(page).to have_nth_table_row_record(2, "CODE2Discount 2 $2 off of Product 2")
      expect(page).to have_current_path(checkout_discounts_path({ column: "revenue", page: 1, sort: "desc" }))

      find(:columnheader, "Uses").click
      expect(page).to have_nth_table_row_record(1, "DISCOUNT3Discount 3 $1 off of all products")
      expect(page).to have_nth_table_row_record(2, "DISCOUNT4Discount 4 $1 off of all products")
      expect(page).to have_current_path(checkout_discounts_path({ column: "uses", page: 1, sort: "asc" }))
      find(:columnheader, "Uses").click
      expect(page).to have_nth_table_row_record(1, "CODE1Discount 1 50% off of Product 1, Product 2, and 1 other")
      expect(page).to have_nth_table_row_record(2, "CODE2Discount 2 $2 off of Product 2")
      expect(page).to have_current_path(checkout_discounts_path({ column: "uses", page: 1, sort: "desc" }))
      find(:columnheader, "Term").click
      expect(page).to have_nth_table_row_record(1, "CODE3Discount 3 50% off of all products")
      expect(page).to have_nth_table_row_record(2, "CODE1Discount 1 50% off of Product 1, Product 2, and 1 other")
      expect(page).to have_current_path(checkout_discounts_path({ column: "term", page: 1, sort: "asc" }))
      find(:columnheader, "Term").click
      expect(page).to have_nth_table_row_record(1, "CODE2Discount 2 $2 off of Product 2")
      expect(page).to have_nth_table_row_record(2, "DISCOUNT3Discount 3 $1 off of all products")
      expect(page).to have_current_path(checkout_discounts_path({ column: "term", page: 1, sort: "desc" }))
    end

    it "sets the page to 1 on sort" do
      visit checkout_discounts_path
      within find("[aria-label='Pagination']") do
        expect(find_button("1")["aria-current"]).to eq("page")
        click_on "2"
        wait_for_ajax
        expect(find_button("1")["aria-current"]).to be_nil
        expect(find_button("2")["aria-current"]).to eq("page")
        expect(page).to have_current_path(checkout_discounts_path({ page: 2 }))
      end

      find(:columnheader, "Discount").click
      wait_for_ajax
      within find("[aria-label='Pagination']") do
        expect(find_button("1")["aria-current"]).to eq("page")
        expect(find_button("2")["aria-current"]).to be_nil
        expect(page).to have_current_path(checkout_discounts_path({ column: "name", page: 1, sort: "asc" }))
      end
    end

    it "sorts based on query parameters on initial page load" do
      visit checkout_discounts_path({ column: "revenue", sort: "desc", page: 1, query: "Discount 3" })
      expect(page).to have_nth_table_row_record(1, "CODE3Discount 3 50% off of all products")
      expect(page).to have_nth_table_row_record(2, "DISCOUNT3Discount 3 $1 off of all products")
    end

    it "handles browser events for going to the previous/next page" do
      visit checkout_discounts_path
      find(:columnheader, "Discount").click
      wait_for_ajax
      page.go_back
      wait_for_ajax
      expect(page).to have_current_path(checkout_discounts_path)
      expect(page).to have_nth_table_row_record(1, "DISCOUNT3Discount 3 $1 off of all products")
      page.go_forward
      wait_for_ajax
      expect(page).to have_current_path(checkout_discounts_path({ column: "name", sort: "asc", page: 1 }))
      expect(page).to have_nth_table_row_record(1, "CODE1Discount 1 50% off of Product 1, Product 2, and 1 other")

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
        expect(page).to have_current_path(checkout_discounts_path(column: "name", sort: "asc", page: 1))
        page.go_forward
        wait_for_ajax
        expect(find_button("1")["aria-current"]).to be_nil
        expect(find_button("2")["aria-current"]).to eq("page")
        expect(page).to have_current_path(checkout_discounts_path({ column: "name", sort: "asc", page: 2 }))
      end
    end
  end

  describe "searching" do
    before do
      create(:offer_code, user: seller, name: "Discount 4", code: "discount4", universal: true)
      stub_const("Checkout::DiscountsController::PER_PAGE", 2)
    end

    it "searches the offer codes" do
      visit checkout_discounts_path

      select_disclosure "Search" do
        fill_in "Search", with: "code"
      end
      wait_for_ajax
      expect(page).to have_nth_table_row_record(1, "CODE1Discount 1 50% off of Product 1, Product 2, and 1 other")
      expect(page).to have_nth_table_row_record(2, "CODE2Discount 2 $2 off of Product 2")
      expect(page).to have_current_path(checkout_discounts_path({ page: 1, query: "code" }))

      find(:columnheader, "Revenue").click
      expect(page).to have_nth_table_row_record(1, "CODE3Discount 3 50% off of all products")
      expect(page).to have_nth_table_row_record(2, "CODE2Discount 2 $2 off of Product 2")
      expect(page).to have_current_path(checkout_discounts_path({ column: "revenue", page: 1, query: "code", sort: "asc" }))

      select_disclosure "Search" do
        fill_in "Search", with: "Discount 4"
      end
      wait_for_ajax
      expect(page).to have_nth_table_row_record(1, "DISCOUNT4Discount 4 $1 off of all products")
      expect(page).to have_current_path(checkout_discounts_path({ column: "revenue", page: 1, query: "Discount 4", sort: "asc" }))
    end
  end
end
