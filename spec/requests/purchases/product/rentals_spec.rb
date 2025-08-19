# frozen_string_literal: true

require("spec_helper")

describe("Rentals from product page", type: :system, js: true) do
  describe "rentals" do
    before do
      @product = create(:product_with_video_file, purchase_type: :buy_and_rent, price_cents: 500, rental_price_cents: 200, name: "rental test")
    end

    it "allows the product to be bought" do
      visit "/l/#{@product.unique_permalink}"

      add_to_cart(@product)
      check_out(@product)

      expect(Purchase.last.price_cents).to eq 500
    end

    it "allows the product to be rented" do
      visit "/l/#{@product.unique_permalink}"

      add_to_cart(@product, rent: true)
      check_out(@product)

      expect(Purchase.last.price_cents).to eq 200
      expect(Purchase.last.is_rental).to be(true)
      expect(UrlRedirect.last.is_rental).to be(true)
    end

    it "allows the product to be rented for free if the rental price is 0" do
      @product.update!(rental_price_cents: 0)
      visit "/l/#{@product.unique_permalink}"

      add_to_cart(@product, rent: true)
      check_out(@product, is_free: true)

      expect(Purchase.last.price_cents).to eq 0
      expect(Purchase.last.is_rental).to be(true)
      expect(UrlRedirect.last.is_rental).to be(true)
    end

    it "allows the product to be rented for free with an offer code" do
      offer_code = create(:offer_code, products: [@product], amount_cents: 500)
      visit URI::DEFAULT_PARSER.escape("/l/#{@product.unique_permalink}/#{offer_code.code}")
      choose "Rent"
      expect(page).to have_selector("[role='status']", text: "$5 off will be applied at checkout (Code #{offer_code.code.upcase})")
      expect(page).to have_radio_button("Rent", text: "$2 $0")
      expect(page).to have_radio_button("Buy", text: "$5 $0")

      add_to_cart(@product, rent: true, offer_code:)
      check_out(@product, is_free: true)

      expect(Purchase.last.price_cents).to eq 0
      expect(Purchase.last.is_rental).to be(true)
      expect(UrlRedirect.last.is_rental).to be(true)
    end

    it "allows the product to be bought for free with an offer code" do
      offer_code = create(:offer_code, products: [@product], amount_cents: 500)
      visit URI::DEFAULT_PARSER.escape("/l/#{@product.unique_permalink}/#{offer_code.code}")

      add_to_cart(@product, offer_code:)
      check_out(@product, is_free: true)

      expect(Purchase.last.price_cents).to eq 0
      expect(Purchase.last.is_rental).to be(false)
      expect(UrlRedirect.last.is_rental).to be(false)
    end

    it "allows the product to be rented for free with an offer code that would only make rental free" do
      offer_code = create(:offer_code, products: [@product], amount_cents: 200)
      visit URI::DEFAULT_PARSER.escape("/l/#{@product.unique_permalink}/#{offer_code.code}")
      wait_for_ajax

      add_to_cart(@product, rent: true, offer_code:)
      check_out(@product, is_free: true)

      expect(Purchase.last.price_cents).to eq 0
      expect(Purchase.last.is_rental).to be(true)
      expect(UrlRedirect.last.is_rental).to be(true)
    end

    it "allows the PWYW product to be rented for free with an offer code that would only make rental free" do
      @product.customizable_price = true
      @product.save!

      offer_code = create(:offer_code, products: [@product], amount_cents: 200)
      visit URI::DEFAULT_PARSER.escape("/l/#{@product.unique_permalink}/#{offer_code.code}")
      wait_for_ajax

      add_to_cart(@product, rent: true, pwyw_price: 0, offer_code:)
      check_out(@product, is_free: true)

      expect(Purchase.last.price_cents).to eq 0
      expect(Purchase.last.is_rental).to be(true)
      expect(UrlRedirect.last.is_rental).to be(true)
    end

    it "allows the product to be rented if it's rent-only" do
      @product.update!(purchase_type: :rent_only)
      visit "/l/#{@product.unique_permalink}"

      add_to_cart(@product, rent: true)
      check_out(@product)

      expect(Purchase.last.price_cents).to eq 200
      expect(Purchase.last.is_rental).to be(true)
      expect(UrlRedirect.last.is_rental).to be(true)
    end

    describe "rentals and vat" do
      before do
        allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("2.47.255.255") # Italy
        allow_any_instance_of(Chargeable).to receive(:country) { "IT" }

        create(:zip_tax_rate, country: "IT", zip_code: nil, state: nil, combined_rate: 0.22, is_seller_responsible: false)
      end

      it "shows the price without the decimal part if the price is a whole number" do
        ZipTaxRate.destroy_all
        create(:zip_tax_rate, country: "IT", zip_code: nil, state: nil,
                              combined_rate: 1, is_seller_responsible: false)
        visit "/l/#{@product.unique_permalink}"
        wait_for_ajax
        add_to_cart(@product)
        wait_for_ajax

        expect(page).to have_text("VAT US$5", normalize_ws: true)
        expect(page).to have_text("Total US$10", normalize_ws: true)

        click_on "Remove"
        visit("/l/#{@product.unique_permalink}")
        wait_for_ajax

        add_to_cart(@product, rent: true)

        expect(page).to have_text("VAT US$2", normalize_ws: true)
        expect(page).to have_text("Total US$4", normalize_ws: true)
      end

      it "charges the right VAT amount on rental purchase" do
        visit "/l/#{@product.unique_permalink}"
        add_to_cart(@product, rent: true)

        expect(page).to have_text("VAT US$0.44", normalize_ws: true)
        expect(page).to have_text("Total US$2.44", normalize_ws: true)

        check_out(@product, zip_code: nil)

        expect(Purchase.last.price_cents).to eq 200
        expect(Purchase.last.total_transaction_cents).to be(244)
        expect(Purchase.last.gumroad_tax_cents).to be(44)
        expect(Purchase.last.was_purchase_taxable).to be(true)
        expect(UrlRedirect.last.is_rental).to be(true)
      end
    end

    describe "with options" do
      before do
        variant_category = create(:variant_category, link: @product, title: "type")
        create(:variant, variant_category:, name: "Option A", price_difference_cents: 1_00)
        create(:variant, variant_category:, name: "Option B", price_difference_cents: 5_00)
      end

      it "shows appropriate price tags in options, that take rent/buy selection into account" do
        visit "/l/#{@product.unique_permalink}"

        choose "Buy"

        expect(page).to have_radio_button(text: "$6\nOption A")
        expect(page).to have_radio_button(text: "$10\nOption B")

        choose "Rent"

        expect(page).to have_radio_button(text: "$3\nOption A")
        expect(page).to have_radio_button(text: "$7\nOption B")
      end

      it "checks out buy + option successfully" do
        visit "/l/#{@product.unique_permalink}"

        choose "Buy"
        choose "Option B"

        expect(page).to have_radio_button(text: "$10\nOption B")

        add_to_cart(@product, option: "Option B")
        check_out(@product)

        expect(Purchase.last.price_cents).to eq 10_00
      end

      it "checks out rent + option successfully" do
        visit "/l/#{@product.unique_permalink}"

        choose "Rent"
        choose "Option A"

        expect(page).to have_radio_button(text: "$3\nOption A")

        add_to_cart(@product, rent: true, option: "Option A")
        check_out(@product)

        expect(Purchase.last.price_cents).to eq 3_00
        expect(Purchase.last.is_rental).to be(true)
        expect(UrlRedirect.last.is_rental).to be(true)
      end
    end
  end
end
