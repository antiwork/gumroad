# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/creator_dashboard_page"

describe("Checkout upsells page", type: :system, js: true) do
  let(:seller) { create(:named_seller, :eligible_for_service_products) }
  let(:product1) { create(:product_with_digital_versions, user: seller, price_cents: 1000, name: "Product 1") }
  let(:product2) { create(:product_with_digital_versions, user: seller, price_cents: 500, name: "Product 2") }
  let!(:upsell1) { create(:upsell, product: product1, variant: product1.alive_variants.second, name: "Upsell 1", seller:, cross_sell: true, offer_code: create(:offer_code, user: seller, products: [product1]), updated_at: 2.days.ago) }
  let!(:upsell2) { create(:upsell, product: product2, name: "Upsell 2", seller:, updated_at: 1.day.ago) }
  let!(:upsell2_variant) { create(:upsell_variant, upsell: upsell2, selected_variant: product2.alive_variants.first, offered_variant: product2.alive_variants.second) }
  let!(:universal_upsell) { create(:upsell, product: product1, name: "Universal Upsell", seller:, cross_sell: true, universal: true) }

  before do
    product1.alive_variants.second.update!(price_difference_cents: 500)
    product2.alive_variants.second.update!(price_difference_cents: 500)

    build_list :product, 2, user: seller do |product, i|
      product.name = "Product #{i + 3}"
      create_list(:upsell_purchase, 2, upsell: upsell1, selected_product: product)
      upsell1.selected_products << product
    end

    create_list(:upsell_purchase, 5, upsell: upsell2, selected_product: product2, upsell_variant: upsell2_variant)
  end

  include_context "with switching account to user as admin for seller"

  it_behaves_like "creator dashboard page", "Checkout" do
    let (:path) { checkout_upsells_path }
  end

  describe "upsells table" do
    it "displays all upsells correctly" do
      visit checkout_upsells_path

      upsell1_row = find(:table_row, { "Upsell" => "Upsell 1", "Revenue" => "$40", "Uses" => "4" })
      within upsell1_row do
        expect(page).to have_text("Product 1 - Untitled 2")
      end
      upsell1_row.click
      within_section "Upsell 1", section_element: :aside do
        within_section "Details" do
          expect(page).to have_text("Offer text Take advantage of this excellent offer", normalize_ws: true)
          expect(page).to have_text("Uses 4", normalize_ws: true)
          expect(page).to have_text("Revenue $40", normalize_ws: true)
          expect(page).to have_text("Discount $1", normalize_ws: true)
        end

        within_section "Selected products" do
          expect(page).to have_text("Product 3 2 uses from this product", normalize_ws: true)
          expect(page).to have_text("Product 4 2 uses from this product", normalize_ws: true)
        end

        within_section "Offered product" do
          expect(page).to have_text("Product 1 - Untitled 2")
        end

        expect(page).to_not have_section("Selected product", exact: true)
        expect(page).to_not have_section("Offers")

        expect(page).to have_button("Edit")
        expect(page).to have_button("Duplicate")
        expect(page).to have_button("Delete")
      end

      upsell2_row = find(:table_row, { "Upsell" => "Upsell 2", "Revenue" => "$25", "Uses" => "5" })
      within upsell2_row do
        expect(page).to have_text("Product 2")
      end
      upsell2_row.click
      within_section "Upsell 2", section_element: :aside do
        within_section "Details" do
          expect(page).to have_text("Offer text Take advantage of this excellent offer", normalize_ws: true)
          expect(page).to have_text("Uses 5", normalize_ws: true)
          expect(page).to have_text("Revenue $25", normalize_ws: true)

          expect(page).to_not have_text("Discount")
        end

        within_section "Selected product" do
          expect(page).to have_text("Product 2")
        end

        within_section "Offers" do
          expect(page).to have_text("Untitled 1 → Untitled 2 5 uses", normalize_ws: true)
        end

        expect(page).to_not have_section("Selected products")
        expect(page).to_not have_section("Offered product")

        expect(page).to have_button("Edit")
        expect(page).to have_button("Duplicate")
        expect(page).to have_button("Delete")
      end

      universal_upsell_row = find(:table_row, { "Upsell" => "Universal Upsell" })
      universal_upsell_row.click
      within_section "Universal Upsell", section_element: :aside do
        within_section "Selected products" do
          expect(page).to have_content("All products")
        end
      end
    end

    context "when the creator has no upsells" do
      it "displays a placeholder message" do
        login_as create(:user)
        visit checkout_upsells_path

        within_section "Offering an upsell at checkout" do
          expect(page).to have_text("Upsells allow you to suggest additional products to your customer at checkout. You can nudge them to purchase either an upgraded version or an extra product add-on.")
          click_on "New upsell"
        end

        expect(page).to have_section("Create an upsell")
      end
    end

    describe "sorting and pagination" do
      before do
        stub_const("Checkout::UpsellsController::PER_PAGE", 1)
        universal_upsell.destroy!
      end

      it "sorts and paginates the upsells" do
        visit checkout_upsells_path
        expect(page).to have_table "Upsells", with_rows: [{ "Upsell" => "Upsell 2" }]
        expect(page).to have_button("1", aria: { current: "page" })
        click_on "Next"
        expect(page).to have_table "Upsells", with_rows: [{ "Upsell" => "Upsell 1" }]
        expect(page).to have_button("2", aria: { current: "page" })
        click_on "Previous"
        expect(page).to have_table "Upsells", with_rows: [{ "Upsell" => "Upsell 2" }]
        expect(page).to have_button("1", aria: { current: "page" })

        find(:columnheader, "Upsell").click
        expect(page).to have_button("1", aria: { current: "page" })
        expect(page).to have_table "Upsells", with_rows: [{ "Upsell" => "Upsell 1" }]
        click_on "2"
        expect(page).to have_button("2", aria: { current: "page" })
        expect(page).to have_table "Upsells", with_rows: [{ "Upsell" => "Upsell 2" }]

        find(:columnheader, "Revenue").click
        expect(page).to have_button("1", aria: { current: "page" })
        expect(page).to have_table "Upsells", with_rows: [{ "Upsell" => "Upsell 2" }]
        click_on "Next"
        expect(page).to have_button("2", aria: { current: "page" })
        expect(page).to have_table "Upsells", with_rows: [{ "Upsell" => "Upsell 1" }]

        find(:columnheader, "Uses").click
        expect(page).to have_button("1", aria: { current: "page" })
        expect(page).to have_table "Upsells", with_rows: [{ "Upsell" => "Upsell 1" }]
        click_on "Next"
        expect(page).to have_button("2", aria: { current: "page" })
        expect(page).to have_table "Upsells", with_rows: [{ "Upsell" => "Upsell 2" }]
      end
    end
  end

  describe "upsell creation" do
    it "allows creating an upsell" do
      visit checkout_upsells_path
      click_on "New upsell"

      choose "Replace the version selected with another version of the same product"

      fill_in "Name", with: "Complete course upsell"

      fill_in "Offer text", with: "My cool upsell"
      fill_in "Offer description", with: "This is a really cool upsell"
      choose "Paused"

      in_preview do
        within_modal "My cool upsell" do
          expect(page).to have_text("This is a really cool upsell")
        end
      end

      fill_in "Offer text", with: "Enhance your learning experience"
      fill_in "Offer description", with: "You'll enjoy a range of exclusive features, including..."
      in_preview do
        within_modal "Enhance your learning experience" do
          expect(page).to have_text("You'll enjoy a range of exclusive features, including...")
        end
      end

      select_combo_box_option search: "Product 1", from: "Apply to this product"
      select_combo_box_option search: "Untitled 1", from: "Version to offer for Untitled 2"
      in_preview do
        within_modal "Enhance your learning experience" do
          expect(page).to have_radio_button("Untitled 1", text: "$10")
        end
      end

      within find("[aria-label='Upsell versions']") do
        click_on "Clear value"
      end
      select_combo_box_option search: "Untitled 2", from: "Version to offer for Untitled 1"
      in_preview do
        within_modal "Enhance your learning experience" do
          expect(page).to have_radio_button("Untitled 2", text: "$15")
        end
      end

      click_on "Save"

      expect(page).to have_alert(text: "Successfully created upsell!")

      find(:table_row, { "Upsell" => "Complete course upsell" }).click

      within_section "Complete course upsell", section_element: :aside do
        within_section "Details" do
          expect(page).to have_text("Offer text Enhance your learning experience", normalize_ws: true)
          expect(page).to have_text("Uses 0", normalize_ws: true)
          expect(page).to have_text("Revenue $0", normalize_ws: true)
          expect(page).to have_text("Status Paused", normalize_ws: true)
        end

        within_section "Selected product" do
          expect(page).to have_text("Product 1")
        end

        within_section "Offers" do
          expect(page).to have_text("Untitled 1 → Untitled 2")
          expect(page).to have_text("0 uses")
        end

        expect(page).to_not have_section("Selected products")
        expect(page).to_not have_section("Offered product")
      end

      upsell = seller.upsells.last
      expect(upsell.name).to eq("Complete course upsell")
      expect(upsell.text).to eq("Enhance your learning experience")
      expect(upsell.description).to eq("You'll enjoy a range of exclusive features, including...")
      expect(upsell.cross_sell).to eq(false)
      expect(upsell.product).to eq(product1)
      expect(upsell.upsell_variants.first.selected_variant).to eq(product1.alive_variants.first)
      expect(upsell.upsell_variants.first.offered_variant).to eq(product1.alive_variants.second)
    end

    context "when a product is archived" do
      before { product1.update!(archived: true) }

      it "doens't include the product in the product list" do
        visit checkout_upsells_path
        click_on "New upsell"

        find(:label, "Apply to these products").click
        expect(page).to have_combo_box "Apply to these products", options: (2..7).map { |i| "Product #{i}" }
        send_keys(:escape)

        find(:label, "Product to offer").click
        expect(page).to have_combo_box "Product to offer", options: (2..7).map { |i| "Product #{i}" }
      end
    end

    context "when the creator has a call product" do
      before { create(:call_product, user: seller, name: "Product Call") }

      it "can have a upsell but cannot be offered as a upsell" do
        visit checkout_upsells_path
        click_on "New upsell"

        find(:label, "Apply to these products").click
        expect(page).to have_combo_box "Apply to these products", with_options: ["Product Call"]
        send_keys(:escape)

        find(:label, "Product to offer").click
        expect(page).not_to have_combo_box "Product to offer", with_options: ["Product Call"]
      end
    end

    it "allows creating a cross-sell upsell" do
      visit checkout_upsells_path
      click_on "New upsell"

      choose "Replace the selected products with another product"

      fill_in "Name", with: "Complete course upsell"

      fill_in "Offer text", with: "My cool upsell"
      fill_in "Offer description", with: "This is a really cool upsell"
      in_preview do
        within_modal "My cool upsell" do
          expect(page).to have_text("This is a really cool upsell")
        end
      end

      fill_in "Offer text", with: "Enhance your learning experience"
      fill_in "Offer description", with: "You'll enjoy a range of exclusive features, including..."
      in_preview do
        within_modal "Enhance your learning experience" do
          expect(page).to have_text("You'll enjoy a range of exclusive features, including...")
        end
      end

      select_combo_box_option search: "Product 1", from: "Apply to these products"
      select_combo_box_option search: "Product 3", from: "Product to offer"
      in_preview do
        within_modal "Enhance your learning experience" do
          within_section "Product 3", section_element: :article do
            expect(page).to have_link("Seller")
            expect(page).to have_selector("[itemprop='price']", text: "$1")
          end
        end
      end

      find(:label, "Product to offer").click
      select_combo_box_option search: "Product 2", from: "Product to offer"
      select_combo_box_option search: "Untitled 2", from: "Version to offer"
      in_preview do
        within_modal "Enhance your learning experience" do
          within_section "Product 2 - Untitled 2", section_element: :article do
            expect(page).to have_link("Seller")
            expect(page).to have_selector("[itemprop='price']", text: "$10")
          end
        end
      end

      find(:label, "Version to offer").click
      select_combo_box_option search: "Untitled 1", from: "Version to offer"
      in_preview do
        within_modal "Enhance your learning experience" do
          within_section "Product 2 - Untitled 1", section_element: :article do
            expect(page).to have_selector("[itemprop='price']", text: "$5")
          end
        end
      end

      check "Add discount to the offered product"
      fill_in "Percentage", with: "20"
      in_preview do
        within_modal "Enhance your learning experience" do
          within_section "Product 2 - Untitled 1", section_element: :article do
            expect(page).to have_selector("[itemprop='price']", text: "$5 $4")
          end
        end
      end

      click_on "Save"

      expect(page).to have_alert(text: "Successfully created upsell!")

      find(:table_row, { "Upsell" => "Complete course upsell" }).click

      within_section "Complete course upsell", section_element: :aside do
        within_section "Details" do
          expect(page).to have_text("Offer text Enhance your learning experience", normalize_ws: true)
          expect(page).to have_text("Discount 20%", normalize_ws: true)
          expect(page).to have_text("Uses 0", normalize_ws: true)
          expect(page).to have_text("Revenue $0", normalize_ws: true)
        end

        within_section "Selected products" do
          expect(page).to have_text("Product 1")
          expect(page).to have_text("0 uses from this product")
        end

        within_section "Offered product" do
          expect(page).to have_text("Product 2 - Untitled 1")
        end

        expect(page).to_not have_section("Selected product", exact: true)
        expect(page).to_not have_section("Offers")
      end

      upsell = seller.upsells.last
      expect(upsell.name).to eq("Complete course upsell")
      expect(upsell.text).to eq("Enhance your learning experience")
      expect(upsell.description).to eq("You'll enjoy a range of exclusive features, including...")
      expect(upsell.cross_sell).to eq(true)
      expect(upsell.replace_selected_products).to eq(true)
      expect(upsell.universal).to eq(false)
      expect(upsell.product).to eq(product2)
      expect(upsell.variant).to eq(product2.alive_variants.first)
      expect(upsell.selected_products).to eq([product1])
      expect(upsell.offer_code.amount_percentage).to eq(20)
      expect(upsell.offer_code.products).to eq([product2])
    end

    it "allows creating a universal cross-sell upsell" do
      visit checkout_upsells_path
      click_on "New upsell"

      fill_in "Name", with: "Complete course upsell"

      fill_in "Offer text", with: "My cool upsell"
      fill_in "Offer description", with: "This is a really cool upsell"
      in_preview do
        within_modal "My cool upsell" do
          expect(page).to have_text("This is a really cool upsell")
        end
      end

      fill_in "Offer text", with: "Enhance your learning experience"
      fill_in "Offer description", with: "You'll enjoy a range of exclusive features, including..."

      check "All products"
      select_combo_box_option search: "Product 1", from: "Product to offer"
      select_combo_box_option search: "Untitled 2", from: "Version to offer"

      click_on "Save"

      expect(page).to have_alert(text: "Successfully created upsell!")

      find(:table_row, { "Upsell" => "Complete course upsell" }).click

      upsell = seller.upsells.last
      expect(upsell.name).to eq("Complete course upsell")
      expect(upsell.text).to eq("Enhance your learning experience")
      expect(upsell.description).to eq("You'll enjoy a range of exclusive features, including...")
      expect(upsell.cross_sell).to eq(true)
      expect(upsell.replace_selected_products).to eq(false)
      expect(upsell.universal).to eq(true)
      expect(upsell.product).to eq(product1)
      expect(upsell.variant).to eq(product1.alive_variants.second)
      expect(upsell.selected_products).to eq([])
      expect(upsell.offer_code).to eq(nil)
    end

    it "validates the upsell form" do
      visit checkout_upsells_path
      click_on "New upsell"

      click_on "Save"
      expect(page).to have_alert(text: "Please complete all required fields.")
      expect(find_field("Name")["aria-invalid"]).to eq("true")
      expect(find_field("Offer text")["aria-invalid"]).to eq("true")
      expect(find_field("Apply to these products")["aria-invalid"]).to eq("true")
      expect(find_field("Product to offer")["aria-invalid"]).to eq("true")

      select_combo_box_option search: "Product 1", from: "Product to offer"
      wait_for_ajax

      click_on "Save"

      expect(find_field("Version to offer")["aria-invalid"]).to eq("true")

      choose "Replace the version selected with another version of the same product"

      click_on "Save"
      expect(page).to have_alert(text: "Please complete all required fields.")
      expect(find_field("Apply to this product")["aria-invalid"]).to eq("true")
    end
  end

  describe "upsell editing" do
    it "allows updating an upsell to a cross-sell" do
      visit checkout_upsells_path

      find(:table_row, { "Upsell" => "Upsell 2" }).click
      click_on "Edit"

      choose "Add another product to the cart"

      fill_in "Name", with: "Complete course upsell", fill_options: { clear: :backspace }
      fill_in "Offer text", with: "Enhance your learning experience", fill_options: { clear: :backspace }
      fill_in "Offer description", with: "You'll enjoy a range of exclusive features, including...", fill_options: { clear: :backspace }

      select_combo_box_option search: "Product 1", from: "Apply to these products"
      select_combo_box_option search: "Product 2", from: "Product to offer"
      select_combo_box_option search: "Untitled 1", from: "Version to offer"

      check "Add discount to the offered product"
      choose "Percentage"
      fill_in "Percentage", with: "20"

      click_on "Save"

      expect(page).to have_alert(text: "Successfully updated upsell!")

      find(:table_row, { "Upsell" => "Complete course upsell" }).click

      within_section "Complete course upsell", section_element: :aside do
        within_section "Details" do
          expect(page).to have_text("Offer text Enhance your learning experience", normalize_ws: true)
          expect(page).to have_text("Discount 20%", normalize_ws: true)
          expect(page).to have_text("Uses 5", normalize_ws: true)
          expect(page).to have_text("Revenue $25", normalize_ws: true)
        end

        within_section "Selected products" do
          expect(page).to have_text("Product 1")
          expect(page).to have_text("0 uses from this product")
        end

        within_section "Offered product" do
          expect(page).to have_text("Product 2 - Untitled 1")
        end

        expect(page).to_not have_section("Selected product", exact: true)
        expect(page).to_not have_section("Offers")
      end

      upsell2.reload
      expect(upsell2.name).to eq("Complete course upsell")
      expect(upsell2.text).to eq("Enhance your learning experience")
      expect(upsell2.description).to eq("You'll enjoy a range of exclusive features, including...")
      expect(upsell2.cross_sell).to eq(true)
      expect(upsell2.replace_selected_products).to eq(false)
      expect(upsell2.universal).to eq(false)
      expect(upsell2.product).to eq(product2)
      expect(upsell2.variant).to eq(product2.alive_variants.first)
      expect(upsell2.selected_products).to eq([product1])
      expect(upsell2.offer_code.amount_percentage).to eq(20)
      expect(upsell2.offer_code.products).to eq([product2])
    end

    it "allows updating a cross-sell to an upsell" do
      visit checkout_upsells_path

      find(:table_row, { "Upsell" => "Upsell 1" }).click
      click_on "Edit"

      fill_in "Name", with: "Complete course upsell"
      fill_in "Offer text", with: "Enhance your learning experience"
      fill_in "Offer description", with: "You'll enjoy a range of exclusive features, including..."

      choose "Replace the version selected with another version of the same product"

      select_combo_box_option search: "Product 1", from: "Apply to this product"
      select_combo_box_option search: "Untitled 2", from: "Version to offer for Untitled 1"

      click_on "Save"

      expect(page).to have_alert(text: "Successfully updated upsell!")

      find(:table_row, { "Upsell" => "Complete course upsell" }).click

      within_section "Complete course upsell", section_element: :aside do
        within_section "Details" do
          expect(page).to have_text("Offer text Enhance your learning experience", normalize_ws: true)
          expect(page).to have_text("Uses 4", normalize_ws: true)
          expect(page).to have_text("Revenue $40", normalize_ws: true)
        end

        within_section "Selected product" do
          expect(page).to have_text("Product 1")
        end

        within_section "Offers" do
          expect(page).to have_text("Untitled 1 → Untitled 2")
          expect(page).to have_text("0 uses")
        end

        expect(page).to_not have_section("Selected products")
        expect(page).to_not have_section("Offered product")
      end

      upsell1.reload
      expect(upsell1.name).to eq("Complete course upsell")
      expect(upsell1.text).to eq("Enhance your learning experience")
      expect(upsell1.description).to eq("You'll enjoy a range of exclusive features, including...")
      expect(upsell1.cross_sell).to eq(false)
      expect(upsell1.product).to eq(product1)
      expect(upsell1.upsell_variants.first.selected_variant).to eq(product1.alive_variants.first)
      expect(upsell1.upsell_variants.first.offered_variant).to eq(product1.alive_variants.second)
    end

    context "when has archived products" do
      let(:selected_product) { upsell1.selected_products.first }
      let(:product) { upsell1.product }

      before do
        product.update!(archived: true)
        selected_product.update!(archived: true)
      end

      it "preserves the archived products on save" do
        visit checkout_upsells_path

        find(:table_row, { "Upsell" => "Upsell 1" }).click
        click_on "Edit"

        find(:label, "Apply to these products").click
        expect(page).to have_combo_box "Apply to these products", options: (2..7).map { |i| "Product #{i}" }
        send_keys(:escape)

        expect(page).to have_text(selected_product.name)

        click_on "Save"

        expect(upsell1.reload.product).to eq(product)
        expect(upsell1.selected_products).to include(selected_product)
      end
    end
  end

  it "allows deleting the selected upsell" do
    visit checkout_upsells_path

    find(:table_row, { "Upsell" => "Upsell 2" }).click
    click_on "Delete"
    expect(page).to have_alert(text: "Successfully deleted upsell!")
    expect(page).to_not have_selector(:table_row, { "Upsell" => "Upsell 2" })

    visit checkout_upsells_path
    expect(page).to_not have_selector(:table_row, { "Upsell" => "Upsell 2" })

    expect(upsell2.reload.deleted_at).to be_present
    expect(upsell2_variant.reload.deleted_at).to be_present

    find(:table_row, { "Upsell" => "Upsell 1" }).click
    click_on "Delete"
    expect(page).to have_alert(text: "Successfully deleted upsell!")
    expect(page).to_not have_selector(:table_row, { "Upsell" => "Upsell 1" })


    visit checkout_upsells_path
    expect(page).to_not have_selector(:table_row, { "Upsell" => "Upsell 1" })

    expect(upsell1.reload.deleted_at).to be_present
    expect(upsell1.offer_code.reload.deleted_at).to be_present
  end

  it "allows pausing the selected upsell" do
    visit checkout_upsells_path

    find(:table_row, { "Upsell" => "Upsell 2" }).click
    within_section "Upsell 2", section_element: :aside do
      within_section "Details" do
        expect(page).to have_text("Status Live", normalize_ws: true)
      end
      click_on "Pause upsell"
    end

    expect(page).to have_alert(text: "Upsell paused and will not appear at checkout.")

    find(:table_row, { "Upsell" => "Upsell 2", "Status" => "Paused" }).click
    within_section "Upsell 2", section_element: :aside do
      within_section "Details" do
        expect(page).to have_text("Status Paused", normalize_ws: true)
      end
    end

    expect(upsell2.reload.paused).to eq(true)
  end

  it "allows resuming the selected upsell" do
    upsell2.update!(paused: true)

    visit checkout_upsells_path

    find(:table_row, { "Upsell" => "Upsell 2", "Status" => "Paused" }).click
    within_section "Upsell 2", section_element: :aside do
      within_section "Details" do
        expect(page).to have_text("Status Paused", normalize_ws: true)
      end
      click_on "Resume upsell"
    end

    expect(page).to have_alert(text: "Upsell resumed and will appear at checkout.")

    find(:table_row, { "Upsell" => "Upsell 2", "Status" => "Live" }).click
    within_section "Upsell 2", section_element: :aside do
      within_section "Details" do
        expect(page).to have_text("Status Live", normalize_ws: true)
      end
    end

    expect(upsell2.reload.paused).to eq(false)
  end

  it "allows duplicating the selected upsell" do
    visit checkout_upsells_path

    find(:table_row, { "Upsell" => "Upsell 1" }).click
    click_on "Duplicate"

    expect(find_field("Name").value).to eq("Upsell 1 (copy)")

    fill_in "Name", with: "Complete course upsell"
    fill_in "Offer text", with: "Enhance your learning experience"
    fill_in "Offer description", with: "You'll enjoy a range of exclusive features, including..."

    choose "Replace the version selected with another version of the same product"

    select_combo_box_option search: "Product 1", from: "Apply to this product"
    select_combo_box_option search: "Untitled 2", from: "Version to offer for Untitled 1"

    click_on "Save"

    expect(page).to have_alert(text: "Successfully created upsell!")

    find(:table_row, { "Upsell" => "Complete course upsell" }).click

    within_section "Complete course upsell", section_element: :aside do
      within_section "Details" do
        expect(page).to have_text("Offer text Enhance your learning experience", normalize_ws: true)
        expect(page).to have_text("Uses 0", normalize_ws: true)
        expect(page).to have_text("Revenue $0", normalize_ws: true)
      end

      within_section "Selected product" do
        expect(page).to have_text("Product 1")
      end

      within_section "Offers" do
        expect(page).to have_text("Untitled 1 → Untitled 2")
        expect(page).to have_text("0 uses")
      end

      expect(page).to_not have_section("Selected products")
      expect(page).to_not have_section("Offered product")
    end

    upsell = seller.upsells.last
    expect(upsell.name).to eq("Complete course upsell")
    expect(upsell.text).to eq("Enhance your learning experience")
    expect(upsell.description).to eq("You'll enjoy a range of exclusive features, including...")
    expect(upsell.cross_sell).to eq(false)
    expect(upsell.replace_selected_products).to eq(false)
    expect(upsell.product).to eq(product1)
    expect(upsell.upsell_variants.first.selected_variant).to eq(product1.alive_variants.first)
    expect(upsell.upsell_variants.first.offered_variant).to eq(product1.alive_variants.second)
  end

  it "allows duplicating the selected cross-sell" do
    visit checkout_upsells_path

    find(:table_row, { "Upsell" => "Upsell 2" }).click
    click_on "Duplicate"

    expect(find_field("Name").value).to eq("Upsell 2 (copy)")

    fill_in "Name", with: "Complete course upsell", fill_options: { clear: :backspace }
    fill_in "Offer text", with: "Enhance your learning experience", fill_options: { clear: :backspace }
    fill_in "Offer description", with: "You'll enjoy a range of exclusive features, including...", fill_options: { clear: :backspace }

    choose "Add another product to the cart"

    select_combo_box_option search: "Product 1", from: "Apply to these products", match: :first
    select_combo_box_option search: "Product 2", from: "Product to offer"
    select_combo_box_option search: "Untitled 1", from: "Version to offer"

    check "Add discount to the offered product"
    fill_in "Percentage", with: "20"

    click_on "Save"

    expect(page).to have_alert(text: "Successfully created upsell!")

    find(:table_row, { "Upsell" => "Complete course upsell" }).click

    within_section "Complete course upsell", section_element: :aside do
      within_section "Details" do
        expect(page).to have_text("Offer text Enhance your learning experience", normalize_ws: true)
        expect(page).to have_text("Discount 20%", normalize_ws: true)
        expect(page).to have_text("Uses 0", normalize_ws: true)
        expect(page).to have_text("Revenue $0", normalize_ws: true)
      end

      within_section "Selected products" do
        expect(page).to have_text("Product 1")
        expect(page).to have_text("0 uses from this product")
      end

      within_section "Offered product" do
        expect(page).to have_text("Product 2 - Untitled 1")
      end

      expect(page).to_not have_section("Selected product", exact: true)
      expect(page).to_not have_section("Offers")
    end

    upsell = seller.upsells.last
    expect(upsell.name).to eq("Complete course upsell")
    expect(upsell.text).to eq("Enhance your learning experience")
    expect(upsell.description).to eq("You'll enjoy a range of exclusive features, including...")
    expect(upsell.cross_sell).to eq(true)
    expect(upsell.replace_selected_products).to eq(false)
    expect(upsell.universal).to eq(false)
    expect(upsell.product).to eq(product2)
    expect(upsell.variant).to eq(product2.alive_variants.first)
    expect(upsell.selected_products).to eq([product1])
    expect(upsell.offer_code.amount_percentage).to eq(20)
    expect(upsell.offer_code.products).to eq([product2])
  end
end
