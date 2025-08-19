# frozen_string_literal: true

require("spec_helper")

describe("Generate invoice for purchase", type: :system, js: true) do
  context "when purchasing from a product page" do
    before do
      @product = create(:product)
      @product2 = create(:product)
    end

    it "shows a link to generate invoice" do
      visit @product.long_url
      add_to_cart(@product)
      visit @product2.long_url
      add_to_cart(@product2)
      @product2.update(price_cents: 600)
      check_out(@product2, error: "The price just changed! Refresh the page for the updated price.")
      expect(page).to have_content("Need an invoice for this? Generate")
      purchase = Purchase.last
      expect(page).to have_link "Generate", href: generate_invoice_by_buyer_path(purchase.external_id, email: purchase.email)
    end
  end

  context "when purchasing from user profile" do
    before do
      @creator = create(:user)
      @product = create(:product, user: @creator, unique_permalink: "aa")
      @product2 = create(:product, user: @creator, unique_permalink: "bb")
    end

    it "shows a link to generate invoice" do
      expect do
        visit @product.long_url
        add_to_cart(@product)
        visit @product2.long_url
        add_to_cart(@product2)
        @product2.update(price_cents: 600)
        check_out(@product2, error: "The price just changed! Refresh the page for the updated price.")

        purchase = Purchase.last
        expect(page).to have_link "Generate", href: generate_invoice_by_buyer_path(purchase.external_id, email: purchase.email)
      end.to change { Purchase.successful.count }.by(1)
    end
  end

  describe "generating an invoice" do
    before do
      @creator = create(:user, name: "US Seller")
      @product = create(:product, user: @creator)
      @physical_product = create(:physical_product, user: @creator)
    end

    it "allows the user to customize and download invoice" do
      purchase = create(:physical_purchase, link: @physical_product)

      visit generate_invoice_by_buyer_path(purchase.external_id, email: purchase.email)

      # Form should be pre-filled with existing purchase info
      expect(find_field("Full name").value).to eq(purchase.full_name)
      expect(find_field("Street address").value).to eq(purchase.street_address)
      expect(find_field("City").value).to eq(purchase.city)
      expect(find_field("State").value).to eq(purchase.state)
      expect(find_field("ZIP code").value).to eq(purchase.zip_code)

      # Edit name and address
      fill_in("Full name", with: "Wonderful Alice")
      fill_in("Street address", with: "Crooked St.")
      fill_in("City", with: "Wonderland")
      fill_in("State", with: "CA")
      fill_in("ZIP code", with: "12345")

      within find("h5", text: "Supplier").first(:xpath, ".//..") do
        expect(page).not_to have_content("VAT Registration Number")
        expect(page).not_to have_content(GUMROAD_VAT_REGISTRATION_NUMBER)
        expect(page).to have_content(purchase.seller.name_or_username)
        expect(page).to have_content(purchase.seller.email)
        expect(page).to have_content("Products supplied by Gumroad.")
      end

      within find("h5", text: "Invoice").first(:xpath, ".//..") do
        expect(page).to have_content "Wonderful Alice Crooked St. Wonderland, CA 12345 United States", normalize_ws: true
        expect(page).not_to have_content("Additional notes")
      end

      fill_in("Additional notes", with: "Custom information.")

      within find("h5", text: "Invoice").first(:xpath, ".//..") do
        expect(page).to have_content "Additional notes"
        expect(page).to have_content "Custom information."
      end

      click_on "Download"
      wait_for_ajax

      invoice_url = find_link("here")[:href]
      reader = PDF::Reader.new(URI.open(invoice_url))
      expect(reader.pages.size).to be(1)

      pdf_text = reader.page(1).text.squish

      expect(pdf_text).to include(purchase.external_id_numeric.to_s)
      expect(pdf_text).to include("Wonderful Alice")
      expect(pdf_text).to include("Crooked St.")
      expect(pdf_text).to include("Wonderland, CA, 12345 United States")
      expect(pdf_text).to include("Item purchased")
      expect(pdf_text).to include(purchase.email)
      expect(pdf_text).to include(purchase.link.name)
      expect(pdf_text).to include(purchase.formatted_non_refunded_total_transaction_amount)
      expect(pdf_text).to include("Additional notes")
      expect(pdf_text).to include("Custom information.")
      expect(pdf_text).to_not include("VAT Registration Number")
      expect(pdf_text).to_not include(GUMROAD_VAT_REGISTRATION_NUMBER)
      expect(pdf_text).to have_content("Products supplied by Gumroad.")
    end

    it "shows Gumroad's VAT registration number for EU purchases" do
      purchase = create(:purchase, link: @product, country: "Italy", quantity: 2)

      visit generate_invoice_by_buyer_path(purchase.external_id, email: purchase.email)

      fill_in("Full name", with: "Wonderful Alice")
      fill_in("Street address", with: "Crooked St.")
      fill_in("City", with: "Wonderland")
      fill_in("State", with: "CA")
      fill_in("ZIP code", with: "12345")

      within find("h5", text: "Supplier").first(:xpath, ".//..//..") do
        expect(page).to have_content("VAT Registration Number")
        expect(page).to have_content(GUMROAD_VAT_REGISTRATION_NUMBER)
      end

      click_on "Download"

      invoice_url = find_link("here")[:href]

      reader = PDF::Reader.new(URI.open(invoice_url))
      expect(reader.pages.size).to be(1)

      pdf_text = reader.page(1).text.squish
      expect(pdf_text).to include(purchase.external_id_numeric.to_s)
      expect(pdf_text).to include(purchase.email)
      expect(pdf_text).to include("Item purchased")
      expect(pdf_text).to include("#{purchase.link.name} ×")
      expect(pdf_text).to include(purchase.quantity.to_s)
      expect(pdf_text).to include(purchase.formatted_non_refunded_total_transaction_amount)
      expect(pdf_text).to include("VAT Registration Number")
      expect(pdf_text).to include(GUMROAD_VAT_REGISTRATION_NUMBER)
    end

    it "shows Gumroad's ABN for Australian purchases" do
      purchase = create(:purchase, link: @product, country: "Australia")

      visit generate_invoice_by_buyer_path(purchase.external_id, email: purchase.email)

      fill_in("Full name", with: "Wonderful Alice")
      fill_in("Street address", with: "Crooked St.")
      fill_in("City", with: "Wonderland")
      fill_in("State", with: "CA")
      fill_in("ZIP code", with: "12345")

      within find("h5", text: "Supplier").first(:xpath, ".//..//..") do
        expect(page).to have_content("Australian Business Number")
        expect(page).to have_content(GUMROAD_AUSTRALIAN_BUSINESS_NUMBER)
      end

      click_on "Download"

      invoice_url = find_link("here")[:href]

      reader = PDF::Reader.new(URI.open(invoice_url))
      expect(reader.pages.size).to be(1)

      pdf_text = reader.page(1).text.squish
      expect(pdf_text).to include(purchase.external_id_numeric.to_s)
      expect(pdf_text).to include(purchase.email)
      expect(pdf_text).to include("Item purchased")
      expect(pdf_text).to include(purchase.link.name)
      expect(pdf_text).to include(purchase.formatted_non_refunded_total_transaction_amount)
      expect(pdf_text).to include(purchase.quantity.to_s)
      expect(pdf_text).to include("Australian Business Number")
      expect(pdf_text).to include(GUMROAD_AUSTRALIAN_BUSINESS_NUMBER)
    end

    it "shows Gumroad's QST registration number for recommended Canada purchases" do
      purchase = create(:purchase, link: @product, country: "Canada", was_product_recommended: true)

      visit generate_invoice_by_buyer_path(purchase.external_id, email: purchase.email)

      fill_in("Full name", with: "Wonderful Alice")
      fill_in("Street address", with: "Crooked St.")
      fill_in("City", with: "Wonderland")
      fill_in("State", with: "CA")
      fill_in("ZIP code", with: "12345")

      within find("h5", text: "Supplier").first(:xpath, ".//..//..") do
        expect(page).to have_content("QST Registration Number")
        expect(page).to have_content(GUMROAD_QST_REGISTRATION_NUMBER)
        expect(page).to have_content("Canada GST Registration Number")
        expect(page).to have_content(GUMROAD_CANADA_GST_REGISTRATION_NUMBER)
      end

      click_on "Download"

      invoice_url = find_link("here")[:href]

      reader = PDF::Reader.new(URI.open(invoice_url))
      expect(reader.pages.size).to be(1)

      pdf_text = reader.page(1).text.squish
      expect(pdf_text).to include(purchase.external_id_numeric.to_s)
      expect(pdf_text).to include(purchase.email)
      expect(pdf_text).to include("Item purchased")
      expect(pdf_text).to include(purchase.link.name)
      expect(pdf_text).to include(purchase.formatted_non_refunded_total_transaction_amount)
      expect(pdf_text).to include(purchase.quantity.to_s)
      expect(pdf_text).to include("QST Registration Number")
      expect(pdf_text).to include(GUMROAD_QST_REGISTRATION_NUMBER)
      expect(pdf_text).to include("Canada GST Registration Number")
      expect(pdf_text).to include(GUMROAD_CANADA_GST_REGISTRATION_NUMBER)
    end

    it "shows Gumroad's Norway VAT registration for Norwegian purchases" do
      purchase = create(:purchase, link: @product, country: "Norway")

      visit generate_invoice_by_buyer_path(purchase.external_id, email: purchase.email)

      fill_in("Full name", with: "Wonderful Alice")
      fill_in("Street address", with: "Crooked St.")
      fill_in("City", with: "Wonderland")
      fill_in("State", with: "CA")
      fill_in("ZIP code", with: "12345")

      within find("h5", text: "Supplier").first(:xpath, ".//..//..") do
        expect(page).to have_content("Norway VAT Registration")
        expect(page).to have_content(GUMROAD_NORWAY_VAT_REGISTRATION)
      end

      click_on "Download"

      invoice_url = find_link("here")[:href]

      reader = PDF::Reader.new(URI.open(invoice_url))
      expect(reader.pages.size).to be(1)

      pdf_text = reader.page(1).text.squish
      expect(pdf_text).to include(purchase.external_id_numeric.to_s)
      expect(pdf_text).to include(purchase.email)
      expect(pdf_text).to include("Item purchased")
      expect(pdf_text).to include(purchase.link.name)
      expect(pdf_text).to include(purchase.formatted_non_refunded_total_transaction_amount)
      expect(pdf_text).to include("Norway VAT Registration")
      expect(pdf_text).to include(GUMROAD_NORWAY_VAT_REGISTRATION)
    end

    it "shows Gumroad's TRN for Bahrain purchases" do
      purchase = create(:purchase, link: @product, country: "Bahrain")

      visit generate_invoice_by_buyer_path(purchase.external_id, email: purchase.email)

      fill_in("Full name", with: "Wonderful Alice")
      fill_in("Street address", with: "Crooked St.")
      fill_in("City", with: "Wonderland")
      fill_in("State", with: "CA")
      fill_in("ZIP code", with: "12345")

      within find("h5", text: "Supplier").first(:xpath, ".//..//..") do
        expect(page).to have_content("VAT Registration Number")
        expect(page).to have_content(GUMROAD_OTHER_TAX_REGISTRATION)
      end

      click_on "Download"

      invoice_url = find_link("here")[:href]

      reader = PDF::Reader.new(URI.open(invoice_url))
      expect(reader.pages.size).to be(1)

      pdf_text = reader.page(1).text.squish
      expect(pdf_text).to include(purchase.external_id_numeric.to_s)
      expect(pdf_text).to include(purchase.email)
      expect(pdf_text).to include("Item purchased")
      expect(pdf_text).to include(purchase.link.name)
      expect(pdf_text).to include(purchase.formatted_non_refunded_total_transaction_amount)
      expect(pdf_text).to include("VAT Registration Number")
      expect(pdf_text).to include(GUMROAD_OTHER_TAX_REGISTRATION)
    end

    it "shows Gumroad's KRA PIN for Kenya purchases" do
      purchase = create(:purchase, link: @product, country: "Kenya")

      visit generate_invoice_by_buyer_path(purchase.external_id, email: purchase.email)

      fill_in("Full name", with: "Wonderful Alice")
      fill_in("Street address", with: "Crooked St.")
      fill_in("City", with: "Wonderland")
      fill_in("State", with: "CA")
      fill_in("ZIP code", with: "12345")

      within find("h5", text: "Supplier").first(:xpath, ".//..//..") do
        expect(page).to have_content("VAT Registration Number")
        expect(page).to have_content(GUMROAD_OTHER_TAX_REGISTRATION)
      end

      click_on "Download"

      invoice_url = find_link("here")[:href]

      reader = PDF::Reader.new(URI.open(invoice_url))
      expect(reader.pages.size).to be(1)

      pdf_text = reader.page(1).text.squish
      expect(pdf_text).to include(purchase.external_id_numeric.to_s)
      expect(pdf_text).to include(purchase.email)
      expect(pdf_text).to include("Item purchased")
      expect(pdf_text).to include(purchase.link.name)
      expect(pdf_text).to include(purchase.formatted_non_refunded_total_transaction_amount)
      expect(pdf_text).to include("VAT Registration Number")
      expect(pdf_text).to include(GUMROAD_OTHER_TAX_REGISTRATION)
    end

    it "shows Gumroad's FIRS TIN for Nigeria purchases" do
      purchase = create(:purchase, link: @product, country: "Nigeria")

      visit generate_invoice_by_buyer_path(purchase.external_id, email: purchase.email)

      fill_in("Full name", with: "Wonderful Alice")
      fill_in("Street address", with: "Crooked St.")
      fill_in("City", with: "Wonderland")
      fill_in("State", with: "CA")
      fill_in("ZIP code", with: "12345")

      within find("h5", text: "Supplier").first(:xpath, ".//..//..") do
        expect(page).to have_content("VAT Registration Number")
        expect(page).to have_content(GUMROAD_OTHER_TAX_REGISTRATION)
      end

      click_on "Download"

      invoice_url = find_link("here")[:href]

      reader = PDF::Reader.new(URI.open(invoice_url))
      expect(reader.pages.size).to be(1)

      pdf_text = reader.page(1).text.squish
      expect(pdf_text).to include(purchase.external_id_numeric.to_s)
      expect(pdf_text).to include(purchase.email)
      expect(pdf_text).to include("Item purchased")
      expect(pdf_text).to include(purchase.link.name)
      expect(pdf_text).to include(purchase.formatted_non_refunded_total_transaction_amount)
      expect(pdf_text).to include("VAT Registration Number")
      expect(pdf_text).to include(GUMROAD_OTHER_TAX_REGISTRATION)
    end

    it "shows Gumroad's TRA TIN for Tanzania purchases" do
      purchase = create(:purchase, link: @product, country: "Tanzania")

      visit generate_invoice_by_buyer_path(purchase.external_id, email: purchase.email)

      fill_in("Full name", with: "Wonderful Alice")
      fill_in("Street address", with: "Crooked St.")
      fill_in("City", with: "Wonderland")
      fill_in("State", with: "CA")
      fill_in("ZIP code", with: "12345")

      within find("h5", text: "Supplier").first(:xpath, ".//..//..") do
        expect(page).to have_content("VAT Registration Number")
        expect(page).to have_content(GUMROAD_OTHER_TAX_REGISTRATION)
      end

      click_on "Download"

      invoice_url = find_link("here")[:href]

      reader = PDF::Reader.new(URI.open(invoice_url))
      expect(reader.pages.size).to be(1)

      pdf_text = reader.page(1).text.squish
      expect(pdf_text).to include(purchase.external_id_numeric.to_s)
      expect(pdf_text).to include(purchase.email)
      expect(pdf_text).to include("Item purchased")
      expect(pdf_text).to include(purchase.link.name)
      expect(pdf_text).to include(purchase.formatted_non_refunded_total_transaction_amount)
      expect(pdf_text).to include("VAT Registration Number")
      expect(pdf_text).to include(GUMROAD_OTHER_TAX_REGISTRATION)
    end

    it "shows Gumroad's VAT registration number for Oman purchases" do
      purchase = create(:purchase, link: @product, country: "Oman")

      visit generate_invoice_by_buyer_path(purchase.external_id, email: purchase.email)

      fill_in("Full name", with: "Wonderful Alice")
      fill_in("Street address", with: "Crooked St.")
      fill_in("City", with: "Wonderland")
      fill_in("State", with: "CA")
      fill_in("ZIP code", with: "12345")

      within find("h5", text: "Supplier").first(:xpath, ".//..//..") do
        expect(page).to have_content("VAT Registration Number")
        expect(page).to have_content(GUMROAD_OTHER_TAX_REGISTRATION)
      end

      click_on "Download"

      invoice_url = find_link("here")[:href]

      reader = PDF::Reader.new(URI.open(invoice_url))
      expect(reader.pages.size).to be(1)

      pdf_text = reader.page(1).text.squish
      expect(pdf_text).to include(purchase.external_id_numeric.to_s)
      expect(pdf_text).to include(purchase.email)
      expect(pdf_text).to include("Item purchased")
      expect(pdf_text).to include(purchase.link.name)
      expect(pdf_text).to include(purchase.formatted_non_refunded_total_transaction_amount)
      expect(pdf_text).to include("VAT Registration Number")
      expect(pdf_text).to include(GUMROAD_OTHER_TAX_REGISTRATION)
    end

    it "shows Gumroad's Tax Registration Number for other countries that collect tax on all products" do
      purchase = create(:purchase, link: @product, country: "Iceland")

      visit generate_invoice_by_buyer_path(purchase.external_id, email: purchase.email)

      fill_in("Full name", with: "Wonderful Alice")
      fill_in("Street address", with: "Crooked St.")
      fill_in("City", with: "Wonderland")
      fill_in("State", with: "CA")
      fill_in("ZIP code", with: "12345")

      within find("h5", text: "Supplier").first(:xpath, ".//..//..") do
        expect(page).to have_content("VAT Registration Number")
        expect(page).to have_content(GUMROAD_OTHER_TAX_REGISTRATION)
      end

      click_on "Download"

      invoice_url = find_link("here")[:href]

      reader = PDF::Reader.new(URI.open(invoice_url))
      expect(reader.pages.size).to be(1)

      pdf_text = reader.page(1).text.squish
      expect(pdf_text).to include(purchase.external_id_numeric.to_s)
      expect(pdf_text).to include(purchase.email)
      expect(pdf_text).to include("Item purchased")
      expect(pdf_text).to include(purchase.link.name)
      expect(pdf_text).to include(purchase.formatted_non_refunded_total_transaction_amount)
      expect(pdf_text).to include("VAT Registration Number")
      expect(pdf_text).to include(GUMROAD_OTHER_TAX_REGISTRATION)
    end

    it "shows Gumroad's Tax Registration Number for other countries that collect tax on digital products" do
      purchase = create(:purchase, link: @product, country: "Chile")

      visit generate_invoice_by_buyer_path(purchase.external_id, email: purchase.email)

      fill_in("Full name", with: "Wonderful Alice")
      fill_in("Street address", with: "Crooked St.")
      fill_in("City", with: "Wonderland")
      fill_in("State", with: "CA")
      fill_in("ZIP code", with: "12345")

      within find("h5", text: "Supplier").first(:xpath, ".//..//..") do
        expect(page).to have_content("VAT Registration Number")
        expect(page).to have_content(GUMROAD_OTHER_TAX_REGISTRATION)
      end

      click_on "Download"

      invoice_url = find_link("here")[:href]

      reader = PDF::Reader.new(URI.open(invoice_url))
      expect(reader.pages.size).to be(1)

      pdf_text = reader.page(1).text.squish
      expect(pdf_text).to include(purchase.external_id_numeric.to_s)
      expect(pdf_text).to include(purchase.email)
      expect(pdf_text).to include("Item purchased")
      expect(pdf_text).to include(purchase.link.name)
      expect(pdf_text).to include(purchase.formatted_non_refunded_total_transaction_amount)
      expect(pdf_text).to include("VAT Registration Number")
      expect(pdf_text).to include(GUMROAD_OTHER_TAX_REGISTRATION)
    end

    it "shows Gumroad as the supplier for a physical product sale" do
      purchase = create(:physical_purchase, link: @physical_product, country: "Australia")

      visit generate_invoice_by_buyer_path(purchase.external_id, email: purchase.email)

      fill_in("Full name", with: "Wonderful Alice")
      fill_in("Street address", with: "Crooked St.")
      fill_in("City", with: "Wonderland")
      fill_in("State", with: "CA")
      fill_in("ZIP code", with: "12345")

      within find("h5", text: "Supplier").first(:xpath, ".//..//..") do
        expect(page).to have_content("Supplier\nGumroad, Inc")
        expect(page).to have_content(purchase.seller.name_or_username)
        expect(page).to have_content(purchase.seller.email)
        expect(page).to have_content("Products supplied by Gumroad.")
      end

      click_on "Download"

      invoice_url = find_link("here")[:href]

      reader = PDF::Reader.new(URI.open(invoice_url))
      expect(reader.pages.size).to be(1)

      pdf_text = reader.page(1).text.squish
      expect(pdf_text).not_to have_content("Supplier: Gumroad")
      expect(pdf_text).to have_content(purchase.seller.name_or_username)
      expect(pdf_text).to have_content(purchase.seller.email)
      expect(pdf_text).to have_content("Products supplied by Gumroad.")
    end

    it "shows Gumroad as the supplier for a non-physical product sale to the US" do
      purchase = create(:purchase, link: @product, country: "United States")

      visit generate_invoice_by_buyer_path(purchase.external_id, email: purchase.email)

      fill_in("Full name", with: "Wonderful Alice")
      fill_in("Street address", with: "Crooked St.")
      fill_in("City", with: "Wonderland")
      fill_in("State", with: "CA")
      fill_in("ZIP code", with: "12345")

      within find("h5", text: "Supplier").first(:xpath, ".//..//..") do
        expect(page).to have_content(purchase.seller.name_or_username)
        expect(page).to have_content(purchase.seller.email)
        expect(page).to have_content("Products supplied by Gumroad.")
      end

      click_on "Download"

      invoice_url = find_link("here")[:href]

      reader = PDF::Reader.new(URI.open(invoice_url))
      expect(reader.pages.size).to be(1)

      pdf_text = reader.page(1).text.squish
      expect(pdf_text).to have_content(purchase.seller.name_or_username)
      expect(pdf_text).to have_content(purchase.seller.email)
      expect(pdf_text).to have_content("Products supplied by Gumroad.")
    end

    it "shows Gumroad as the supplier for a sale via Gumroad Discover" do
      purchase = create(:purchase, link: @product, country: "United States", was_product_recommended: true, recommended_by: "discover")

      visit generate_invoice_by_buyer_path(purchase.external_id, email: purchase.email)

      fill_in("Full name", with: "Wonderful Alice")
      fill_in("Street address", with: "Crooked St.")
      fill_in("City", with: "Wonderland")
      fill_in("State", with: "CA")
      fill_in("ZIP code", with: "12345")

      within find("h5", text: "Supplier").first(:xpath, ".//..//..") do
        expect(page).to have_content("Gumroad, Inc")
        expect(page).not_to have_content("Products supplied by #{purchase.seller.display_name}.")
      end

      click_on "Download"

      invoice_url = find_link("here")[:href]

      reader = PDF::Reader.new(URI.open(invoice_url))
      expect(reader.pages.size).to be(1)

      pdf_text = reader.page(1).text.squish
      within find("h5", text: "Supplier").first(:xpath, ".//..") do
        expect(pdf_text).to have_content("Gumroad, Inc.")
        expect(pdf_text).not_to have_content("Products supplied by #{purchase.seller.display_name}.")
      end
    end

    it "shows Gumroad as the supplier for a physical product sale" do
      purchase = create(:physical_purchase, link: @physical_product, country: "Australia")

      visit generate_invoice_by_buyer_path(purchase.external_id, email: purchase.email)

      fill_in("Full name", with: "Wonderful Alice")
      fill_in("Street address", with: "Crooked St.")
      fill_in("City", with: "Wonderland")
      fill_in("State", with: "CA")
      fill_in("ZIP code", with: "12345")

      within find("h5", text: "Supplier").first(:xpath, ".//..//..") do
        expect(page).to have_content("Supplier\nGumroad, Inc")
        expect(page).to have_content(purchase.seller.name_or_username)
        expect(page).to have_content(purchase.seller.email)
        expect(page).to have_content("Products supplied by Gumroad.")
      end

      click_on "Download"

      invoice_url = find_link("here")[:href]

      reader = PDF::Reader.new(URI.open(invoice_url))
      expect(reader.pages.size).to be(1)

      pdf_text = reader.page(1).text.squish
      within find("h5", text: "Supplier").first(:xpath, ".//..") do
        expect(pdf_text).to have_content("Gumroad, Inc.")
        expect(pdf_text).to have_content(purchase.seller.name_or_username)
        expect(pdf_text).to have_content(purchase.seller.email)
        expect(pdf_text).to have_content("Products supplied by Gumroad.")
      end
    end

    it "shows Gumroad as the supplier for a non-physical product sale to the US" do
      purchase = create(:purchase, link: @product, country: "United States")

      visit generate_invoice_by_buyer_path(purchase.external_id, email: purchase.email)

      fill_in("Full name", with: "Wonderful Alice")
      fill_in("Street address", with: "Crooked St.")
      fill_in("City", with: "Wonderland")
      fill_in("State", with: "CA")
      fill_in("ZIP code", with: "12345")

      within find("h5", text: "Supplier").first(:xpath, ".//..//..") do
        expect(page).to have_content("Supplier\nGumroad, Inc")
        expect(page).to have_content(purchase.seller.name_or_username)
        expect(page).to have_content(purchase.seller.email)
        expect(page).to have_content("Products supplied by Gumroad.")
      end

      click_on "Download"

      invoice_url = find_link("here")[:href]

      reader = PDF::Reader.new(URI.open(invoice_url))
      expect(reader.pages.size).to be(1)

      pdf_text = reader.page(1).text.squish
      within find("h5", text: "Supplier").first(:xpath, ".//..") do
        expect(pdf_text).to have_content("Gumroad, Inc.")
        expect(pdf_text).to have_content(purchase.seller.name_or_username)
        expect(pdf_text).to have_content(purchase.seller.email)
        expect(pdf_text).to have_content("Products supplied by Gumroad.")
      end
    end
  end
end
