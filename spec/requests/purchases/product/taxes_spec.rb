# frozen_string_literal: true

require("spec_helper")

describe("Product Page - Tax Scenarios", type: :system, js: true) do
  describe "sales tax", shipping: true do
    before do
      @creator = create(:user_with_compliance_info)

      @product = create(:physical_product, user: @creator, require_shipping: true, price_cents: 500_00)
    end

    it "calls the tax endpoint for a real zip code that doesn't show in the enterprise zip codes database" do
      visit("/l/#{@product.unique_permalink}")
      add_to_cart(@product)
      check_out(@product, address: { street: "3029 W Sherman Rd", city: "San Tan Valley", state: "AZ", zip_code: "85144", country: "US" }) do
        expect(page).to have_text("Subtotal US$500", normalize_ws: true)
        expect(page).to have_text("Sales tax US$33.50", normalize_ws: true)
      end

      expect(page).to have_text("Your purchase was successful!")

      expect(Purchase.successful.count).to eq 1

      new_purchase = Purchase.last
      expect(new_purchase.link_id).to eq(@product.id)
      expect(new_purchase.price_cents).to eq(500_00)
      expect(new_purchase.total_transaction_cents).to eq(53_350)
      expect(new_purchase.fee_cents).to eq(65_30) # 500_00 * 0.129 + 50c + 30c
      expect(new_purchase.tax_cents).to eq(0)
      expect(new_purchase.gumroad_tax_cents).to eq(33_50)
      expect(new_purchase.was_tax_excluded_from_price).to eq(true)
      expect(new_purchase.was_purchase_taxable).to eq(true)
      expect(new_purchase.zip_tax_rate).to be_nil
      expect(new_purchase.purchase_sales_tax_info).to_not be(nil)
      expect(new_purchase.purchase_sales_tax_info.ip_address).to_not be(new_purchase.ip_address)
      expect(new_purchase.purchase_sales_tax_info.elected_country_code).to eq(Compliance::Countries::USA.alpha2)
      expect(new_purchase.purchase_sales_tax_info.country_code).to eq(Compliance::Countries::USA.alpha2)
      expect(new_purchase.purchase_sales_tax_info.card_country_code).to eq(Compliance::Countries::USA.alpha2)
      expect(new_purchase.purchase_sales_tax_info.postal_code).to eq("85144")
    end

    describe "price modifiers" do
      it "re-evaluates price and tax when there are variants" do
        variant_category = create(:variant_category, link: @product, title: "type")
        variants = [["type 1", 150], ["type 2", 200]]
        variants.each do |name, price_difference_cents|
          create(:variant, variant_category:, name:, price_difference_cents:)
        end
        Product::SkusUpdaterService.new(product: @product).perform
        Sku.not_is_default_sku.first.update_attribute(:price_difference_cents, 150)

        visit("/l/#{@product.unique_permalink}")
        add_to_cart(@product, option: "type 1")
        check_out(@product, address: { street: "3029 W Sherman Rd", city: "San Tan Valley", state: "AZ", zip_code: "85144" }) do
          expect(page).to have_text("Subtotal US$501.50", normalize_ws: true)
          expect(page).to have_text("Sales tax US$33.60", normalize_ws: true)
          expect(page).to have_text("Total US$535.10", normalize_ws: true)
        end

        expect(page).to have_text("Your purchase was successful!")

        expect(Purchase.successful.count).to eq 1

        new_purchase = Purchase.last
        expect(new_purchase.link_id).to eq(@product.id)
        expect(new_purchase.price_cents).to eq(501_50)
        expect(new_purchase.total_transaction_cents).to eq(535_10)
        expect(new_purchase.fee_cents).to eq(65_49) # 535_10 * 0.129 + 50c + 30c
        expect(new_purchase.gumroad_tax_cents).to eq(33_60)
        expect(new_purchase.tax_cents).to eq(0)
        expect(new_purchase.was_tax_excluded_from_price).to eq(true)
        expect(new_purchase.was_purchase_taxable).to eq(true)
        expect(new_purchase.zip_tax_rate).to be_nil
        expect(new_purchase.purchase_sales_tax_info).to_not be(nil)
        expect(new_purchase.purchase_sales_tax_info.ip_address).to_not be(new_purchase.ip_address)
        expect(new_purchase.purchase_sales_tax_info.elected_country_code).to eq(Compliance::Countries::USA.alpha2)
        expect(new_purchase.purchase_sales_tax_info.country_code).to eq(Compliance::Countries::USA.alpha2)
        expect(new_purchase.purchase_sales_tax_info.card_country_code).to eq(Compliance::Countries::USA.alpha2)
        expect(new_purchase.purchase_sales_tax_info.postal_code).to eq("85144")
      end

      it "re-evaluates price and tax when an offer code is applied - code in url" do
        offer_code = create(:offer_code, products: [@product], amount_cents: 10_000, code: "taxoffer")

        visit "/l/#{@product.unique_permalink}/taxoffer"
        add_to_cart(@product, offer_code:)
        check_out(@product, address: { street: "3029 W Sherman Rd", city: "San Tan Valley", state: "AZ", zip_code: "85144" }) do
          expect(page).to have_text("$500")
          expect(page).to have_text("Subtotal US$500", normalize_ws: true)
          expect(page).to have_text("Sales tax US$26.80", normalize_ws: true)
          expect(page).to have_text("Discounts taxoffer US$-100", normalize_ws: true)
          expect(page).to have_text("Total US$426.80", normalize_ws: true)
        end

        expect(page).to have_text("Your purchase was successful!")

        expect(Purchase.successful.count).to eq 1

        new_purchase = Purchase.last
        expect(new_purchase.link_id).to eq(@product.id)
        expect(new_purchase.price_cents).to eq(400_00)
        expect(new_purchase.total_transaction_cents).to eq(426_80)
        expect(new_purchase.fee_cents).to eq(52_40) # 434_50 * 0.129 + 50c + 30c
        expect(new_purchase.gumroad_tax_cents).to eq(26_80)
        expect(new_purchase.tax_cents).to eq(0)
        expect(new_purchase.was_tax_excluded_from_price).to eq(true)
        expect(new_purchase.was_purchase_taxable).to eq(true)
        expect(new_purchase.zip_tax_rate).to be_nil
        expect(new_purchase.purchase_sales_tax_info).to_not be(nil)
        expect(new_purchase.purchase_sales_tax_info.ip_address).to_not be(new_purchase.ip_address)
        expect(new_purchase.purchase_sales_tax_info.elected_country_code).to eq(Compliance::Countries::USA.alpha2)
        expect(new_purchase.purchase_sales_tax_info.country_code).to eq(Compliance::Countries::USA.alpha2)
        expect(new_purchase.purchase_sales_tax_info.card_country_code).to eq(Compliance::Countries::USA.alpha2)
        expect(new_purchase.purchase_sales_tax_info.postal_code).to eq("85144")
      end

      it "re-evaluates price and tax when a tip is added" do
        @product.user.update!(tipping_enabled: true)

        visit @product.long_url
        add_to_cart(@product)
        fill_checkout_form(@product, address: { street: "3029 W Sherman Rd", city: "San Tan Valley", state: "AZ", zip_code: "85144" })
        expect(page).to have_text("Subtotal US$500", normalize_ws: true)
        expect(page).to_not have_text("Tip US$", normalize_ws: true)
        expect(page).to have_text("Sales tax US$33.50", normalize_ws: true)
        expect(page).to have_text("Total US$533.50", normalize_ws: true)

        choose "10%"
        wait_for_ajax
        expect(page).to have_text("Subtotal US$500", normalize_ws: true)
        expect(page).to have_text("Tip US$50", normalize_ws: true)
        expect(page).to have_text("Sales tax US$36.85", normalize_ws: true)
        expect(page).to have_text("Total US$586.85", normalize_ws: true)

        click_on "Pay"
        expect(page).to have_alert(text: "Your purchase was successful!")

        purchase = Purchase.last
        expect(purchase.link_id).to eq(@product.id)
        expect(purchase.price_cents).to eq(550_00)
        expect(purchase.total_transaction_cents).to eq(586_85)
        expect(purchase.fee_cents).to eq(71_75) # 597_44 * 0.129 + 50c + 30c
        expect(purchase.gumroad_tax_cents).to eq(36_85)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.was_tax_excluded_from_price).to eq(true)
        expect(purchase.was_purchase_taxable).to eq(true)
        expect(purchase.zip_tax_rate).to be_nil
        expect(purchase.purchase_sales_tax_info).to_not be(nil)
        expect(purchase.purchase_sales_tax_info.ip_address).to_not be(purchase.ip_address)
        expect(purchase.purchase_sales_tax_info.elected_country_code).to eq(Compliance::Countries::USA.alpha2)
        expect(purchase.purchase_sales_tax_info.country_code).to eq(Compliance::Countries::USA.alpha2)
        expect(purchase.purchase_sales_tax_info.card_country_code).to eq(Compliance::Countries::USA.alpha2)
        expect(purchase.purchase_sales_tax_info.postal_code).to eq("85144")
        expect(purchase.tip.value_cents).to eq(50_00)
      end
    end
  end

  describe "US sales tax", taxjar: true do
    it "calculates and charges sales tax when WI customer makes purchase" do
      product = create(:product, price_cents: 100_00)
      visit "/l/#{product.unique_permalink}"
      expect(page).to have_text("$100")

      add_to_cart(product)
      check_out(product, zip_code: "53703") do
        expect(page).to have_text("Subtotal US$100", normalize_ws: true)
        expect(page).to have_text("Sales tax US$5.50", normalize_ws: true)
        expect(page).to have_text("Total US$105.50", normalize_ws: true)
      end

      purchase = Purchase.last
      expect(purchase.total_transaction_cents).to eq(105_50)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(5_50)
      expect(purchase.was_purchase_taxable).to be(true)
    end

    it "calculates and charges sales tax when WI customer makes purchase of a physical product" do
      product = create(:physical_product, price_cents: 100_00)
      visit "/l/#{product.unique_permalink}"
      expect(page).to have_text("$100")

      add_to_cart(product)
      check_out(product, address: { street: "1 S Pinckney St", state: "WI", city: "Madison", zip_code: "53703" }) do
        expect(page).to have_text("Subtotal US$100", normalize_ws: true)
        expect(page).to have_text("Sales tax US$5.50", normalize_ws: true)
        expect(page).to have_text("Total US$105.50", normalize_ws: true)
      end

      purchase = Purchase.last
      expect(purchase.total_transaction_cents).to eq(105_50)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(5_50)
      expect(purchase.was_purchase_taxable).to be(true)
    end

    it "calculates and charges sales tax when WA customer makes purchase" do
      product = create(:product, price_cents: 100_00)
      visit "/l/#{product.unique_permalink}"
      expect(page).to have_text("$100")

      add_to_cart(product)
      check_out(product, zip_code: "98121") do
        expect(page).to have_text("Subtotal US$100", normalize_ws: true)
        expect(page).to have_text("Sales tax US$10.35", normalize_ws: true)
        expect(page).to have_text("Total US$110.35", normalize_ws: true)
      end

      purchase = Purchase.last
      expect(purchase.total_transaction_cents).to eq(110_35)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(10_35)
      expect(purchase.was_purchase_taxable).to be(true)
    end

    it "calculates and charges sales tax when WA customer makes purchase of a physical product" do
      product = create(:physical_product, price_cents: 100_00)
      visit "/l/#{product.unique_permalink}"
      expect(page).to have_text("$100")

      add_to_cart(product)
      check_out(product, address: { street: "2031 7th Ave", state: "WA", city: "Seattle", zip_code: "98121" }) do
        expect(page).to have_text("Subtotal US$100", normalize_ws: true)
        expect(page).to have_text("Sales tax US$10.35", normalize_ws: true)
        expect(page).to have_text("Total US$110.35", normalize_ws: true)
      end

      purchase = Purchase.last
      expect(purchase.total_transaction_cents).to eq(110_35)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(10_35)
      expect(purchase.was_purchase_taxable).to be(true)
    end

    it "calculates and charges sales tax when WI customer purchases a non-physical product" do
      product = create(:product, price_cents: 100_00)
      visit "/l/#{product.unique_permalink}"
      expect(page).to have_text("$100")

      add_to_cart(product)
      check_out(product, zip_code: "53703") do
        expect(page).to have_text("Subtotal US$100", normalize_ws: true)
        expect(page).to have_text("Sales tax US$5.50", normalize_ws: true)
        expect(page).to have_text("Total US$105.50", normalize_ws: true)
      end

      purchase = Purchase.last
      expect(purchase.total_transaction_cents).to eq(105_50)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(5_50)
      expect(purchase.was_purchase_taxable).to be(true)
    end

    it "calculates and charges sales tax when WA customer purchases a non-physical product" do
      product = create(:product, price_cents: 100_00)
      visit "/l/#{product.unique_permalink}"
      expect(page).to have_text("$100")

      add_to_cart(product)
      check_out(product, zip_code: "98121") do
        expect(page).to have_text("Subtotal US$100", normalize_ws: true)
        expect(page).to have_text("Sales tax US$10.35", normalize_ws: true)
        expect(page).to have_text("Total US$110.35", normalize_ws: true)
      end

      purchase = Purchase.last
      expect(purchase.total_transaction_cents).to eq(110_35)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(10_35)
      expect(purchase.was_purchase_taxable).to be(true)
    end
  end

  describe "VAT" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "IT", zip_code: nil, state: nil, combined_rate: 0.22, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("2.47.255.255")  # Italy

      @vat_link = create(:product, price_cents: 100_00)
    end

    it "does not show VAT in the ribbon / sticker and charges the right amount" do
      visit "/l/#{@vat_link.unique_permalink}"
      expect(page).to have_selector("[itemprop='offers']", text: "$100")

      add_to_cart(@vat_link)
      check_out(@vat_link, zip_code: nil, credit_card: { number: "4000003800000008" })

      purchase = Purchase.last
      expect(purchase.total_transaction_cents).to eq(122_00)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(22_00)
      expect(purchase.was_purchase_taxable).to be(true)
    end

    it "allows entry of VAT ID and doesn't charge VAT" do
      visit "/l/#{@vat_link.unique_permalink}"
      expect(page).to have_selector("[itemprop='offers']", text: "$100")

      add_to_cart(@vat_link)

      expect(page).to have_text("VAT US$22", normalize_ws: true)
      check_out(@vat_link, vat_id: "NL860999063B01", zip_code: nil, credit_card: { number: "4000003800000008" }) do
        expect(page).not_to have_text("VAT US$", normalize_ws: true)
      end

      purchase = Purchase.last
      expect(purchase.total_transaction_cents).to eq(100_00)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(0)
      expect(purchase.was_purchase_taxable).to be(false)
      expect(purchase.purchase_sales_tax_info.business_vat_id).to eq("NL860999063B01")

      # Check VAT ID is present on the invoice as well

      visit purchase.receipt_url
      click_on("Generate")
      expect(page).to(have_text("NL860999063B01"))
    end

    context "for a tiered membership product" do
      let(:product) { create(:membership_product_with_preset_tiered_pricing) }

      it "displays the correct VAT and charges the right amount" do
        visit "/l/#{product.unique_permalink}"
        add_to_cart(product, option: "First Tier")
        check_out(product, zip_code: nil, credit_card: { number: "4000003800000008" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(3_66)
        expect(purchase.price_cents).to eq(3_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(66)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "allows entry of VAT ID and doesn't charge VAT" do
        visit "/l/#{product.unique_permalink}"
        add_to_cart(product, option: "First Tier")
        expect(page).to(have_text("VAT US$0.66", normalize_ws: true))
        check_out(product, vat_id: "NL860999063B01", zip_code: nil, credit_card: { number: "4000003800000008" }) do
          expect(page).not_to have_text("VAT US$", normalize_ws: true)
        end

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(3_00)
        expect(purchase.price_cents).to eq(3_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
        expect(purchase.purchase_sales_tax_info.business_vat_id).to eq("NL860999063B01")

        # Check VAT ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("NL860999063B01"))
      end
    end

    it "charges the right amount for a VAT country where the GeoIp2 lookup doesn't match IsoCountryCodes" do
      create(:zip_tax_rate, country: "CZ", zip_code: nil, state: nil, combined_rate: 0.21, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("93.99.163.13") # Czechia

      visit "/l/#{@vat_link.unique_permalink}"
      expect(page).to have_text("$100")

      add_to_cart(@vat_link)
      check_out(@vat_link, zip_code: nil, credit_card: { number: "4000002030000002" })

      purchase = Purchase.last
      expect(purchase.country).to eq("Czechia")
      expect(purchase.total_transaction_cents).to eq(121_00)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(21_00)
      expect(purchase.was_purchase_taxable).to be(true)
    end

    it "charges VAT for a physical product" do
      product = create(:physical_product, price_cents: 100_00)
      visit "/l/#{product.unique_permalink}"
      expect(page).to have_text("$100")

      add_to_cart(product)
      check_out(product, address: { street: "Via del Governo Vecchio, 87", city: "Rome", state: "Latium", zip_code: "00186" })

      purchase = Purchase.last
      expect(purchase.total_transaction_cents).to eq(122_00)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(22_00)
      expect(purchase.was_purchase_taxable).to be(true)
    end

    it "displays the correct VAT and charges the right amount" do
      product = create(:physical_product, price_cents: 100_00)
      visit "/l/#{product.unique_permalink}"
      expect(page).to have_text("$100")

      add_to_cart(product)
      check_out(product, address: { street: "Via del Governo Vecchio, 87", city: "Rome", state: "Latium", zip_code: "00186" })

      purchase = Purchase.last
      expect(purchase.total_transaction_cents).to eq(122_00)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(22_00)
      expect(purchase.was_purchase_taxable).to be(true)
    end
  end

  describe "GST" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "AU", zip_code: nil, state: nil, combined_rate: 0.10, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("103.251.65.149")  # Australia

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    it "applies the GST" do
      visit "/l/#{@product.unique_permalink}"
      expect(page).to have_selector("[itemprop='price']", text: "$100")
      add_to_cart(@product)
      expect(page).to have_text("Total US$110", normalize_ws: true)
      check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

      purchase = Purchase.last
      expect(purchase.total_transaction_cents).to eq(110_00)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(10_00)
      expect(purchase.was_purchase_taxable).to be(true)
    end

    it "allows entry of ABN ID and doesn't charge GST" do
      visit "/l/#{@product.unique_permalink}"
      expect(page).to have_selector("[itemprop='offers']", text: "$100")

      add_to_cart(@product)
      expect(page).to have_text("GST")
      check_out(@product, abn_id: "51824753556", zip_code: nil, credit_card: { number: "4000000360000006" }) do
        expect(page).not_to have_text("GST")
      end

      purchase = Purchase.last
      expect(purchase.total_transaction_cents).to eq(100_00)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(0)
      expect(purchase.was_purchase_taxable).to be(false)
      expect(purchase.purchase_sales_tax_info.business_vat_id).to eq("51824753556")

      # Check ABN ID is present on the invoice as well

      visit purchase.receipt_url
      click_on("Generate")
      expect(page).to(have_text("51824753556"))
    end

    it "applies GST for physical products" do
      @product = create(:physical_product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!

      visit "/l/#{@product.unique_permalink}"
      expect(page).to have_selector("[itemprop='offers']", text: "$100")
      add_to_cart(@product)

      expect(page).to have_text("Total US$110", normalize_ws: true)

      check_out(@product, address: { street: "278 Rocky Point Rd", city: "Ramsgate", state: "NSW", zip_code: "2217" })

      purchase = Purchase.last
      expect(purchase.total_transaction_cents).to eq(110_00)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(10_00)
      expect(purchase.was_purchase_taxable).to be(true)
    end

    it "applies GST for physical products" do
      product = create(:physical_product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      product.save!

      visit "/l/#{product.unique_permalink}"
      expect(page).to have_text("$100")
      add_to_cart(product)

      expect(page).to have_text("Total US$110", normalize_ws: true)

      check_out(product, address: { street: "278 Rocky Point Rd", city: "Ramsgate", state: "NSW", zip_code: "2217" })

      purchase = Purchase.last
      expect(purchase.total_transaction_cents).to eq(110_00)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(10_00)
      expect(purchase.was_purchase_taxable).to be(true)
    end
  end

  describe "Singapore GST" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "SG", zip_code: nil, state: nil, combined_rate: 0.08, is_seller_responsible: false, applicable_years: [2023])
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("103.6.151.4")  # Singapore

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    it "applies the GST" do
      travel_to(Time.find_zone("UTC").local(2023, 4, 1)) do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_selector("[itemprop='price']", text: "$100")
        add_to_cart(@product)
        expect(page).to have_text("GST US$8", normalize_ws: true)
        expect(page).to have_text("Total US$108", normalize_ws: true)
        check_out(@product, zip_code: nil, credit_card: { number: "4000007020000003" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(108_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(8_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end
    end

    it "allows entry of GST ID and doesn't charge GST" do
      service_success_response = {
        "returnCode" => "10",
        "data" => {
          "Status" => "Registered"
        }
      }
      expect(HTTParty).to receive(:post).with(IRAS_ENDPOINT, anything).and_return(service_success_response)

      travel_to(Time.find_zone("UTC").local(2023, 4, 1)) do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_selector("[itemprop='offers']", text: "$100")

        add_to_cart(@product)
        expect(page).to have_text("GST US$8", normalize_ws: true)
        check_out(@product, gst_id: "T9100001B", zip_code: nil, credit_card: { number: "4000007020000003" }) do
          expect(page).not_to have_text("GST US$8", normalize_ws: true)
        end

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
        expect(purchase.purchase_sales_tax_info.business_vat_id).to eq("T9100001B")

        # Check GST ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("T9100001B"))
      end
    end

    it "applies GST for physical products" do
      travel_to(Time.find_zone("UTC").local(2023, 4, 1)) do
        @product = create(:physical_product, price_cents: 100_00)

        create(:user_compliance_info_empty, user: @product.user,
                                            first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                            zip_code: "94107", country: Compliance::Countries::USA.common_name)

        @product.save!

        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_selector("[itemprop='offers']", text: "$100")
        add_to_cart(@product)

        expect(page).to have_text("GST US$8", normalize_ws: true)
        expect(page).to have_text("Total US$108", normalize_ws: true)

        check_out(@product, address: { street: "10 Bayfront Ave", city: "Singapore", state: "Singapore", zip_code: "018956" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(108_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(8_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end
    end

    it "applies GST for physical products" do
      travel_to(Time.find_zone("UTC").local(2023, 4, 1)) do
        product = create(:physical_product, price_cents: 100_00)

        create(:user_compliance_info_empty, user: product.user,
                                            first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                            zip_code: "94107", country: Compliance::Countries::USA.common_name)

        product.save!

        visit "/l/#{product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(product)

        expect(page).to have_text("GST US$8", normalize_ws: true)
        expect(page).to have_text("Total US$108", normalize_ws: true)

        check_out(product, address: { street: "10 Bayfront Ave", city: "Singapore", state: "Singapore", zip_code: "018956" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(108_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(8_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end
    end
  end

  describe "Norway Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "NO", state: nil, zip_code: nil, combined_rate: 0.25, is_seller_responsible: false)
      create(:zip_tax_rate, country: "NO", state: nil, zip_code: nil, combined_rate: 0.00, is_seller_responsible: false, is_epublication_rate: true)

      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("84.210.138.89")  # Norway

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    it "applies tax in Norway" do
      visit "/l/#{@product.unique_permalink}"
      expect(page).to have_text("$100")
      add_to_cart(@product)

      expect(page).to have_text("VAT US$25", normalize_ws: true)
      expect(page).to have_text("Total US$125", normalize_ws: true)

      check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

      purchase = Purchase.last
      expect(purchase.total_transaction_cents).to eq(125_00)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(25_00)
      expect(purchase.was_purchase_taxable).to be(true)
    end

    it "applies the epublication tax rate for epublications in Norway" do
      @product.update!(is_epublication: true)

      visit "/l/#{@product.unique_permalink}"
      expect(page).to have_text("$100")
      add_to_cart(@product)

      expect(page).to have_text("Total US$100", normalize_ws: true)

      check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

      purchase = Purchase.last
      expect(purchase.total_transaction_cents).to eq(100_00)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(0)
      expect(purchase.was_purchase_taxable).to be(false)
    end

    it "allows entry of MVA ID and doesn't charge tax" do
      visit "/l/#{@product.unique_permalink}"
      expect(page).to have_text("$100")
      add_to_cart(@product)

      check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, mva_id: "977074010MVA") do
        expect(page).not_to have_text("VAT")
      end

      purchase = Purchase.last
      expect(purchase.total_transaction_cents).to eq(100_00)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(0)
      expect(purchase.was_purchase_taxable).to be(false)

      # Check MVA ID is present on the invoice as well

      visit purchase.receipt_url
      click_on("Generate")
      expect(page).to(have_text("Norway VAT Registration"))
      expect(page).to(have_text("977074010MVA"))
    end
  end

  describe "Iceland Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "IS", state: nil, zip_code: nil, combined_rate: 0.24, is_seller_responsible: false)
      create(:zip_tax_rate, country: "IS", state: nil, zip_code: nil, combined_rate: 0.11, is_seller_responsible: false, is_epublication_rate: true)

      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("213.220.126.106")  # Iceland

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_is feature flag is off" do
      it "does not apply tax in Iceland" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_is feature flag is on" do
      before do
        Feature.activate(:collect_tax_is)
      end

      it "applies tax in Iceland" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$24", normalize_ws: true)
        expect(page).to have_text("Total US$124", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(124_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(24_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "applies the epublication tax rate for epublications in Iceland" do
        @product.update!(is_epublication: true)

        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$11", normalize_ws: true)
        expect(page).to have_text("Total US$111", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(111_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(11_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "allows entry of the Tax ID and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, vsk_id: "528491")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        # Check Tax ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("528491"))
      end
    end
  end

  describe "Japan Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "JP", zip_code: nil, state: nil, combined_rate: 0.10, is_seller_responsible: false)

      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("126.0.0.1") # Japan

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_jp feature flag is off" do
      it "does not apply tax in Japan" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_jp feature flag is on" do
      before do
        Feature.activate(:collect_tax_jp)
      end

      it "applies tax in Japan" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("CT US$10", normalize_ws: true)
        expect(page).to have_text("Total US$110", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(110_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(10_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "allows entry of the Tax ID and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, cn_id: "5-8356-7825-6246")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        # Check Tax ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("5-8356-7825-6246"))
      end
    end
  end

  describe "New Zealand Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "NZ", state: nil, zip_code: nil, combined_rate: 0.15, is_seller_responsible: false)

      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("121.72.165.118")  # New Zealand

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_nz feature flag is off" do
      it "does not apply tax in New Zealand" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_nz feature flag is on" do
      before do
        Feature.activate(:collect_tax_nz)
      end

      it "applies tax in New Zealand" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("GST US$15", normalize_ws: true)
        expect(page).to have_text("Total US$115", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(115_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(15_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "allows entry of the Tax ID and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, ird_id: "NZ62-332-956")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        # Check Tax ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("NZ62-332-956"))
      end
    end
  end

  describe "South Africa Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "ZA", state: nil, zip_code: nil, combined_rate: 0.15, is_seller_responsible: false)

      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("196.25.255.250") # South Africa IP

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_za feature flag is off" do
      it "does not apply tax in South Africa" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_za feature flag is on" do
      before do
        Feature.activate(:collect_tax_za)
      end

      it "applies tax in South Africa" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$15", normalize_ws: true)
        expect(page).to have_text("Total US$115", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(115_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(15_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "allows entry of the Tax ID and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, vat_id: "4734567892")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        # Check Tax ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("4734567892"))
      end
    end
  end

  describe "Switzerland Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "CH", state: nil, zip_code: nil, combined_rate: 0.081, is_seller_responsible: false)
      create(:zip_tax_rate, country: "CH", state: nil, zip_code: nil, combined_rate: 0.026, is_seller_responsible: false, is_epublication_rate: true)

      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("46.140.123.45")  # Switzerland

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_ch feature flag is off" do
      it "does not apply tax in Switzerland" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_ch feature flag is on" do
      before do
        Feature.activate(:collect_tax_ch)
      end

      it "applies tax in Switzerland" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$8.10", normalize_ws: true)
        expect(page).to have_text("Total US$108.10", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(108_10)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(8_10)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "applies reduced tax rate for e-publications" do
        @product.update!(is_epublication: true)

        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$2.60", normalize_ws: true)
        expect(page).to have_text("Total US$102.60", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(102_60)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(2_60)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "allows entry of the Tax ID and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, vat_id: "CHE-123.456.788")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        # Check Tax ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("CHE-123.456.788"))
      end
    end
  end

  describe "United Arab Emirates Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "AE", state: nil, zip_code: nil, combined_rate: 0.05, is_seller_responsible: false)

      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("185.93.245.44")  # UAE

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_ae feature flag is off" do
      it "does not apply tax in UAE" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_ae feature flag is on" do
      before do
        Feature.activate(:collect_tax_ae)
      end

      it "applies tax in UAE" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$5", normalize_ws: true)
        expect(page).to have_text("Total US$105", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(105_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(5_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "allows entry of the Tax ID and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, trn_id: "923456789012345")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        # Check Tax ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("923456789012345"))
      end
    end
  end

  describe "India Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "IN", state: nil, zip_code: nil, combined_rate: 0.18, is_seller_responsible: false)

      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("103.48.196.103")  # India

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_in feature flag is off" do
      it "does not apply tax in India" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_in feature flag is on" do
      before do
        Feature.activate(:collect_tax_in)
      end

      it "applies tax in India" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("GST US$18", normalize_ws: true)
        expect(page).to have_text("Total US$118", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(118_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(18_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "allows entry of the Tax ID and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, gst_id: "27AAPFU0939F1ZV")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        # Check Tax ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("27AAPFU0939F1ZV"))
      end
    end
  end

  describe "Bahrain Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "BH", state: nil, zip_code: nil, combined_rate: 0.10, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("77.69.128.1") # Bahrain

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_bh feature flag is off" do
      it "does not apply tax in Bahrain" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_bh feature flag is on" do
      before do
        Feature.activate(:collect_tax_bh)
      end

      it "applies tax in Bahrain" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)


        expect(page).to have_text("VAT US$10", normalize_ws: true)
        expect(page).to have_text("Total US$110", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(110_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(10_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "does not apply tax for physical products" do
        physical_product = create(:physical_product, price_cents: 100_00)

        visit "/l/#{physical_product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(physical_product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Manama", zip_code: "12345", state: "BH", country: "BH" }, credit_card: { number: "4000000360000006" }, should_verify_address: true)

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of TRN and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, trn_id: "123456789012345")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("123456789012345"))
      end
    end
  end

  describe "Belarus Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "BY", state: nil, zip_code: nil, combined_rate: 0.20, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("93.84.113.217") # Belarus

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_by feature flag is off" do
      it "does not apply tax in Belarus" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_by feature flag is on" do
      before do
        Feature.activate(:collect_tax_by)
      end

      it "applies tax in Belarus" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$20", normalize_ws: true)
        expect(page).to have_text("Total US$120", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(120_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(20_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "does not apply tax for physical products" do
        physical_product = create(:physical_product, price_cents: 100_00)

        visit "/l/#{physical_product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(physical_product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Minsk", zip_code: "220000", state: "BY", country: "BY" }, credit_card: { number: "4000000360000006" }, should_verify_address: true)

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, unp_id: "623456785")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        # Check Tax ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("623456785"))
      end
    end
  end

  describe "Chile Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "CL", state: nil, zip_code: nil, combined_rate: 0.19, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("200.68.0.1") # Chile

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_cl feature flag is off" do
      it "does not apply tax in Chile" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_cl feature flag is on" do
      before do
        Feature.activate(:collect_tax_cl)
      end

      it "applies tax in Chile" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$19", normalize_ws: true)
        expect(page).to have_text("Total US$119", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(119_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(19_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "does not apply tax for physical products" do
        physical_product = create(:physical_product, price_cents: 100_00)

        visit "/l/#{physical_product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(physical_product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Santiago", zip_code: "7500000", state: "CL", country: "CL" }, credit_card: { number: "4000000360000006" }, should_verify_address: true)

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, rut_id: "72345678-9")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        # Check Tax ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("72345678-9"))
      end
    end
  end

  describe "Colombia Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "CO", state: nil, zip_code: nil, combined_rate: 0.19, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("181.49.0.1") # Colombia

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_co feature flag is off" do
      it "does not apply tax in Colombia" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_co feature flag is on" do
      before do
        Feature.activate(:collect_tax_co)
      end

      it "applies tax in Colombia" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$19", normalize_ws: true)
        expect(page).to have_text("Total US$119", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(119_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(19_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "does not apply tax for physical products" do
        physical_product = create(:physical_product, price_cents: 100_00)

        visit "/l/#{physical_product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(physical_product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Bogota, D.C.", zip_code: "110111", state: "CO", country: "CO" }, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, nit_id: "623.456.789-1")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        # Check Tax ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("623.456.789-1"))
      end
    end
  end

  describe "Costa Rica Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "CR", state: nil, zip_code: nil, combined_rate: 0.13, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("186.15.0.1") # Costa Rica

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_cr feature flag is off" do
      it "does not apply tax in Costa Rica" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_cr feature flag is on" do
      before do
        Feature.activate(:collect_tax_cr)
      end

      it "applies tax in Costa Rica" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$13", normalize_ws: true)
        expect(page).to have_text("Total US$113", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(113_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(13_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "does not apply tax for physical products" do
        physical_product = create(:physical_product, price_cents: 100_00)

        visit "/l/#{physical_product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(physical_product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "San José", zip_code: "110111", state: "CR", country: "CR" }, credit_card: { number: "4000000360000006" }, should_verify_address: true)

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, cpj_id: "123456789")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        # Check Tax ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("123456789"))
      end
    end
  end

  describe "Ecuador Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "EC", state: nil, zip_code: nil, combined_rate: 0.12, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("186.101.88.2") # Ecuador

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_ec feature flag is off" do
      it "does not apply tax in Ecuador" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_ec feature flag is on" do
      before do
        Feature.activate(:collect_tax_ec)
      end

      it "applies tax in Ecuador" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$12", normalize_ws: true)
        expect(page).to have_text("Total US$112", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(112_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(12_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "does not apply tax for physical products" do
        physical_product = create(:physical_product, price_cents: 100_00)

        visit "/l/#{physical_product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(physical_product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Quito", zip_code: "170101", state: "EC", country: "EC" }, credit_card: { number: "4000000360000006" }, should_verify_address: true)

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, ruc_id: "1790027740001")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        # Check Tax ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("1790027740001"))
      end
    end
  end

  describe "Egypt Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "EG", state: nil, zip_code: nil, combined_rate: 0.14, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("156.208.0.0") # Egypt

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_eg feature flag is off" do
      it "does not apply tax in Egypt" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_eg feature flag is on" do
      before do
        Feature.activate(:collect_tax_eg)
      end

      it "applies tax in Egypt" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$14", normalize_ws: true)
        expect(page).to have_text("Total US$114", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(114_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(14_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "does not apply tax for physical products" do
        physical_product = create(:physical_product, price_cents: 100_00)

        visit "/l/#{physical_product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(physical_product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Cairo", zip_code: "11511", state: "CA", country: "EG" }, credit_card: { number: "4000000360000006" }, should_verify_address: true)

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, tn_id: "623-456-782")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        # Check Tax ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("623-456-782"))
      end
    end
  end

  describe "Georgia Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "GE", state: nil, zip_code: nil, combined_rate: 0.18, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("31.146.180.0") # Georgia

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_ge feature flag is off" do
      it "does not apply tax in Georgia" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_ge feature flag is on" do
      before do
        Feature.activate(:collect_tax_ge)
      end

      it "applies tax in Georgia" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$18", normalize_ws: true)
        expect(page).to have_text("Total US$118", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(118_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(18_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "does not apply tax for physical products" do
        physical_product = create(:physical_product, price_cents: 100_00)

        visit "/l/#{physical_product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(physical_product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Tbilisi", zip_code: "0100", state: "TB", country: "GE" }, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, tin_id: "123456789")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        # Check Tax ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("123456789"))
      end
    end
  end

  describe "Kazakhstan Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "KZ", state: nil, zip_code: nil, combined_rate: 0.12, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("2.132.97.1") # Kazakhstan

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_kz feature flag is off" do
      it "does not apply tax in Kazakhstan" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_kz feature flag is on" do
      before do
        Feature.activate(:collect_tax_kz)
      end

      it "applies tax in Kazakhstan" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$12", normalize_ws: true)
        expect(page).to have_text("Total US$112", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(112_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(12_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "does not apply tax for physical products" do
        physical_product = create(:physical_product, price_cents: 100_00)

        visit "/l/#{physical_product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(physical_product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Almaty", zip_code: "050000", state: "AL", country: "KZ" }, credit_card: { number: "4000000360000006" }, should_verify_address: true)

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, tin_id: "830302300054")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        # Check Tax ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("830302300054"))
      end
    end
  end

  describe "Kenya Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "KE", state: nil, zip_code: nil, combined_rate: 0.16, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("41.90.0.1") # Kenya

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_ke feature flag is off" do
      it "does not apply tax in Kenya" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_ke feature flag is on" do
      before do
        Feature.activate(:collect_tax_ke)
      end

      it "applies tax in Kenya" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$16", normalize_ws: true)
        expect(page).to have_text("Total US$116", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(116_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(16_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "does not apply tax for physical products" do
        physical_product = create(:physical_product, price_cents: 100_00)

        visit "/l/#{physical_product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(physical_product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Nairobi", zip_code: "00100", state: "NA", country: "KE" }, credit_card: { number: "4000000360000006" }, should_verify_address: true)

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of KRA PIN and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, kra_pin_id: "A123456789P")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("A123456789P"))
      end
    end
  end

  describe "Malaysia Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "MY", state: nil, zip_code: nil, combined_rate: 0.06, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("175.143.0.1") # Malaysia

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_my feature flag is off" do
      it "does not apply tax in Malaysia" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_my feature flag is on" do
      before do
        Feature.activate(:collect_tax_my)
      end

      it "applies tax in Malaysia" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Service tax US$6", normalize_ws: true)
        expect(page).to have_text("Total US$106", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(106_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(6_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "does not apply tax for physical products" do
        physical_product = create(:physical_product, price_cents: 100_00)

        visit "/l/#{physical_product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(physical_product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Kuala Lumpur", zip_code: "50000", state: "WP", country: "MY" }, credit_card: { number: "4000000360000006" }, should_verify_address: true)

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, sst_id: "X89-2104-12345678")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        # Check Tax ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("X89-2104-12345678"))
      end
    end
  end

  describe "Mexico Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "MX", state: nil, zip_code: nil, combined_rate: 0.16, is_seller_responsible: false)
      create(:zip_tax_rate, country: "MX", state: nil, zip_code: nil, combined_rate: 0.00, is_seller_responsible: false, is_epublication_rate: true)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("187.189.0.1") # Mexico

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_mx feature flag is off" do
      it "does not apply tax in Mexico" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_mx feature flag is on" do
      before do
        Feature.activate(:collect_tax_mx)
      end

      it "applies tax in Mexico" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$16", normalize_ws: true)
        expect(page).to have_text("Total US$116", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(116_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(16_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "applies the epublication tax rate for epublications in Mexico" do
        @product.update!(is_epublication: true)

        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "does not apply tax for physical products" do
        physical_product = create(:physical_product, price_cents: 100_00)

        visit "/l/#{physical_product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(physical_product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Mexico City", zip_code: "01000", state: "DF", country: "MX" }, credit_card: { number: "4000000360000006" }, should_verify_address: true)

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, rfc_id: "RTL-630713-7M9")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        # Check Tax ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("RTL-630713-7M9"))
      end
    end
  end

  describe "Moldova Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "MD", state: nil, zip_code: nil, combined_rate: 0.20, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("178.168.0.1") # Moldova

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_md feature flag is off" do
      it "does not apply tax in Moldova" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_md feature flag is on" do
      before do
        Feature.activate(:collect_tax_md)
      end

      it "applies tax in Moldova" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$20", normalize_ws: true)
        expect(page).to have_text("Total US$120", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(120_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(20_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "does not apply tax for physical products" do
        physical_product = create(:physical_product, price_cents: 100_00)

        visit "/l/#{physical_product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(physical_product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Chisinau", zip_code: "MD-2001", state: "Chisinau", country: "MD" }, credit_card: { number: "4000000360000006" }, should_verify_address: true)

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, vat_id: "MD9234564")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        # Check Tax ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("MD9234564"))
      end
    end
  end

  describe "Morocco Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "MA", state: nil, zip_code: nil, combined_rate: 0.20, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("105.158.0.1") # Morocco

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_ma feature flag is off" do
      it "does not apply tax in Morocco" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_ma feature flag is on" do
      before do
        Feature.activate(:collect_tax_ma)
      end

      it "applies tax in Morocco" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$20", normalize_ws: true)
        expect(page).to have_text("Total US$120", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(120_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(20_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "does not apply tax for physical products" do
        physical_product = create(:physical_product, price_cents: 100_00)

        visit "/l/#{physical_product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(physical_product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Rabat", zip_code: "10000", state: "Rabat", country: "MA" }, credit_card: { number: "4000000360000006" }, should_verify_address: true)

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, tin_id: "1234567")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        # Check Tax ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("1234567"))
      end
    end
  end

  describe "Nigeria Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "NG", state: nil, zip_code: nil, combined_rate: 0.075, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("41.184.122.50") # Nigeria

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_ng feature flag is off" do
      it "does not apply tax in Nigeria" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_ng feature flag is on" do
      before do
        Feature.activate(:collect_tax_ng)
      end

      it "applies tax in Nigeria" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$7.50", normalize_ws: true)
        expect(page).to have_text("Total US$107.50", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(107_50)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(7_50)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "does not apply tax for physical products" do
        physical_product = create(:physical_product, price_cents: 100_00)

        visit "/l/#{physical_product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(physical_product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Lagos", zip_code: "10000", state: "Lagos", country: "NG" }, credit_card: { number: "4000000360000006" }, should_verify_address: true)

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the FIRS TIN and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, firs_tin_id: "12345678-1234")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("12345678-1234"))
      end
    end
  end

  describe "Oman Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "OM", state: nil, zip_code: nil, combined_rate: 0.05, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("5.37.0.0") # Oman

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_om feature flag is off" do
      it "does not apply tax in Oman" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_om feature flag is on" do
      before do
        Feature.activate(:collect_tax_om)
      end

      it "applies tax in Oman" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$5", normalize_ws: true)
        expect(page).to have_text("Total US$105", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(105_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(5_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "does not apply tax for physical products" do
        physical_product = create(:physical_product, price_cents: 100_00)

        visit "/l/#{physical_product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(physical_product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Muscat", zip_code: "10000", state: "Muscat", country: "OM" }, credit_card: { number: "4000000360000006" }, should_verify_address: true)

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of VAT Number and doesn't charge VAT" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$5", normalize_ws: true)
        check_out(@product, oman_vat_number: "OM1234567890", zip_code: nil, credit_card: { number: "4000000360000006" }) do
          expect(page).not_to have_text("VAT US$", normalize_ws: true)
        end

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end
  end

  describe "Russia Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "RU", state: nil, zip_code: nil, combined_rate: 0.20, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("95.167.0.0") # Russia

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_ru feature flag is off" do
      it "does not apply tax in Russia" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_ru feature flag is on" do
      before do
        Feature.activate(:collect_tax_ru)
      end

      it "applies tax in Russia" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$20", normalize_ws: true)
        expect(page).to have_text("Total US$120", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(120_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(20_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "does not apply tax for physical products" do
        physical_product = create(:physical_product, price_cents: 100_00)

        visit "/l/#{physical_product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(physical_product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Moscow", zip_code: "10000", state: "Moscow", country: "RU" }, credit_card: { number: "4000000360000006" }, should_verify_address: true)

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, inn_id: "1234567894")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        # Check Tax ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("1234567894"))
      end
    end
  end

  describe "Saudi Arabia Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "SA", state: nil, zip_code: nil, combined_rate: 0.15, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("84.235.49.128") # Saudi Arabia

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_sa feature flag is off" do
      it "does not apply tax in Saudi Arabia" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_sa feature flag is on" do
      before do
        Feature.activate(:collect_tax_sa)
      end

      it "applies tax in Saudi Arabia" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$15", normalize_ws: true)
        expect(page).to have_text("Total US$115", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(115_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(15_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "does not apply tax for physical products" do
        physical_product = create(:physical_product, price_cents: 100_00)

        visit "/l/#{physical_product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(physical_product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Riyadh", zip_code: "10000", state: "Riyadh", country: "SA" }, credit_card: { number: "4000000360000006" }, should_verify_address: true)

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, vat_id: "300710482300003")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        # Check Tax ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("300710482300003"))
      end
    end
  end

  describe "Serbia Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "RS", state: nil, zip_code: nil, combined_rate: 0.20, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("178.220.0.1") # Serbia

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_rs feature flag is off" do
      it "does not apply tax in Serbia" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_rs feature flag is on" do
      before do
        Feature.activate(:collect_tax_rs)
      end

      it "applies tax in Serbia" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$20", normalize_ws: true)
        expect(page).to have_text("Total US$120", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(120_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(20_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "does not apply tax for physical products" do
        physical_product = create(:physical_product, price_cents: 100_00)

        visit "/l/#{physical_product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(physical_product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Belgrade", zip_code: "10000", state: "Belgrade", country: "RS" }, credit_card: { number: "4000000360000006" }, should_verify_address: true)

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, pib_id: "101134702")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        # Check Tax ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("101134702"))
      end
    end
  end

  describe "South Korea Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "KR", state: nil, zip_code: nil, combined_rate: 0.10, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("1.255.49.75") # South Korea

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_kr feature flag is off" do
      it "does not apply tax in South Korea" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_kr feature flag is on" do
      before do
        Feature.activate(:collect_tax_kr)
      end

      it "applies tax in South Korea" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$10", normalize_ws: true)
        expect(page).to have_text("Total US$110", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(110_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(10_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "does not apply tax for physical products" do
        physical_product = create(:physical_product, price_cents: 100_00)

        visit "/l/#{physical_product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(physical_product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Seoul", zip_code: "10000", state: "Seoul", country: "KR" }, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, brn_id: "116-82-00276")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        # Check Tax ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("116-82-00276"))
      end
    end
  end

  describe "Tanzania Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "TZ", state: nil, zip_code: nil, combined_rate: 0.18, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("41.188.156.75") # Tanzania

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_tz feature flag is off" do
      it "does not apply tax in Tanzania" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_tz feature flag is on" do
      before do
        Feature.activate(:collect_tax_tz)
      end

      it "applies tax in Tanzania" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$18", normalize_ws: true)
        expect(page).to have_text("Total US$118", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(118_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(18_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "does not apply tax for physical products" do
        physical_product = create(:physical_product, price_cents: 100_00)

        visit "/l/#{physical_product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(physical_product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Dar es Salaam", zip_code: "10000", state: "Dar es Salaam", country: "TZ" }, credit_card: { number: "4000000360000006" }, should_verify_address: true)

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of TRA TIN and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, tra_tin: "12-345678-A")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("12-345678-A"))
      end
    end
  end

  describe "Thailand Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "TH", state: nil, zip_code: nil, combined_rate: 0.07, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("171.96.70.108") # Thailand

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_th feature flag is off" do
      it "does not apply tax in Thailand" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_th feature flag is on" do
      before do
        Feature.activate(:collect_tax_th)
      end

      it "applies tax in Thailand" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$7", normalize_ws: true)
        expect(page).to have_text("Total US$107", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(107_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(7_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "does not apply tax for physical products" do
        physical_product = create(:physical_product, price_cents: 100_00)

        visit "/l/#{physical_product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(physical_product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Bangkok", zip_code: "10000", state: "Bangkok", country: "TH" }, credit_card: { number: "4000000360000006" }, should_verify_address: true)

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, tin_id: "0105536112014")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        # Check Tax ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("0105536112014"))
      end
    end
  end

  describe "Turkey Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "TR", state: nil, zip_code: nil, combined_rate: 0.20, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("78.188.0.1") # Turkey

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_tr feature flag is off" do
      it "does not apply tax in Turkey" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_tr feature flag is on" do
      before do
        Feature.activate(:collect_tax_tr)
      end

      it "applies tax in Turkey" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$20", normalize_ws: true)
        expect(page).to have_text("Total US$120", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(120_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(20_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "does not apply tax for physical products" do
        physical_product = create(:physical_product, price_cents: 100_00)

        visit "/l/#{physical_product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(physical_product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Istanbul", zip_code: "34000", state: "Istanbul", country: "TR" }, credit_card: { number: "4000000360000006" }, should_verify_address: true)

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, vkn_id: "1729171602")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        # Check Tax ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("1729171602"))
      end
    end
  end

  describe "Ukraine Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "UA", state: nil, zip_code: nil, combined_rate: 0.20, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("176.36.232.147") # Ukraine

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_ua feature flag is off" do
      it "does not apply tax in Ukraine" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_ua feature flag is on" do
      before do
        Feature.activate(:collect_tax_ua)
      end

      it "applies tax in Ukraine" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$20", normalize_ws: true)
        expect(page).to have_text("Total US$120", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(120_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(20_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "does not apply tax for physical products" do
        physical_product = create(:physical_product, price_cents: 100_00)

        visit "/l/#{physical_product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(physical_product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Kyiv", zip_code: "01001", state: "Kyiv", country: "UA" }, credit_card: { number: "4000000360000006" }, should_verify_address: true)

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, edrpou_id: "4928621938")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        # Check Tax ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("4928621938"))
      end
    end
  end

  describe "Uzbekistan Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "UZ", state: nil, zip_code: nil, combined_rate: 0.15, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("91.196.77.77") # Uzbekistan

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_uz feature flag is off" do
      it "does not apply tax in Uzbekistan" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_uz feature flag is on" do
      before do
        Feature.activate(:collect_tax_uz)
      end

      it "applies tax in Uzbekistan" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$15", normalize_ws: true)
        expect(page).to have_text("Total US$115", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(115_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(15_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "does not apply tax for physical products" do
        physical_product = create(:physical_product, price_cents: 100_00)

        visit "/l/#{physical_product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(physical_product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Tashkent", zip_code: "100000", state: "Tashkent", country: "UZ" }, credit_card: { number: "4000000360000006" }, should_verify_address: true)

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, vat_id: "123456789")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        # Check Tax ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("123456789"))
      end
    end
  end

  describe "Vietnam Tax" do
    before do
      Capybara.current_session.driver.browser.manage.delete_all_cookies

      create(:zip_tax_rate, country: "VN", state: nil, zip_code: nil, combined_rate: 0.10, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("113.161.94.110") # Vietnam

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    context "when collect_tax_vn feature flag is off" do
      it "does not apply tax in Vietnam" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end
    end

    context "when collect_tax_vn feature flag is on" do
      before do
        Feature.activate(:collect_tax_vn)
      end

      it "applies tax in Vietnam" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        expect(page).to have_text("VAT US$10", normalize_ws: true)
        expect(page).to have_text("Total US$110", normalize_ws: true)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(110_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(10_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "does not apply tax for physical products" do
        physical_product = create(:physical_product, price_cents: 100_00)

        visit "/l/#{physical_product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(physical_product)

        expect(page).to have_text("Total US$100", normalize_ws: true)

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Hanoi", zip_code: "100000", state: "Hanoi", country: "VN" }, credit_card: { number: "4000000360000006" }, should_verify_address: true)

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax" do
        visit "/l/#{@product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(@product)

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, mst_id: "0193456780-001")

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)

        # Check Tax ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("0193456780-001"))
      end
    end
  end

  describe "Canada Tax", taxjar: true do
    let (:product) { create(:product, price_cents: 100_00) }

    it "detects the province for Canada" do
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("184.65.213.114") # British Columbia, Canada

      visit "/l/#{product.unique_permalink}"
      expect(page).to have_text("$100")
      add_to_cart(product)

      expect(page).to have_select("Country", selected: "Canada")
      expect(page).to have_select("Province", selected: "BC")

      check_out(product, country: "Canada", zip_code: nil, credit_card: { number: "4000001240000000" })

      purchase = Purchase.last
      expect(purchase.country).to eq("Canada")
      expect(purchase.state).to eq("BC")
      expect(purchase.ip_country).to eq("Canada")
      expect(purchase.card_country).to eq("CA")
      expect(purchase.total_transaction_cents).to eq(112_00)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(12_00)
      expect(purchase.was_purchase_taxable).to be(true)
    end

    it "assigns the selected province for Canada" do
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("192.206.151.131") # Ontario, Canada

      visit "/l/#{product.unique_permalink}"
      expect(page).to have_text("$100")
      add_to_cart(product)

      expect(page).to have_select("Country", selected: "Canada")
      expect(page).to have_select("Province", selected: "ON")

      select "QC", from: "Province"
      expect(page).to_not have_field "Business QST ID (optional)"
      check_out(product, zip_code: nil, credit_card: { number: "4000001240000000" })

      purchase = Purchase.last
      expect(purchase.country).to eq("Canada")
      expect(purchase.state).to eq("QC")
      expect(purchase.ip_country).to eq("Canada")
      expect(purchase.card_country).to eq("CA")
      expect(purchase.total_transaction_cents).to eq(114_98)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(14_98)
      expect(purchase.was_purchase_taxable).to be(true)
    end

    it "charges tax Canada" do
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("192.206.151.131") # Ontario, Canada

      visit "/l/#{product.unique_permalink}"
      expect(page).to have_text("$100")
      add_to_cart(product)

      expect(page).to have_select("Country", selected: "Canada")
      expect(page).to have_select("Province", selected: "ON")

      select "QC", from: "Province"
      check_out(product, zip_code: nil, credit_card: { number: "4000001240000000" }) do
        expect(page).to have_text("Subtotal US$100", normalize_ws: true)
        expect(page).to have_text("Tax US$14.98", normalize_ws: true)
      end

      purchase = Purchase.last
      expect(purchase.country).to eq("Canada")
      expect(purchase.state).to eq("QC")
      expect(purchase.ip_country).to eq("Canada")
      expect(purchase.card_country).to eq("CA")
      expect(purchase.total_transaction_cents).to eq(114_98)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(14_98)
      expect(purchase.was_purchase_taxable).to be(true)
    end

    context "when the product is physical" do
      let(:product) { create(:physical_product, price_cents: 100_00) }

      it "allows the customer to select province for a physical product to Canada" do
        allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("192.206.151.131") # Ontario, Canada

        visit "/l/#{product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(product)

        expect(page).to have_select("Country", selected: "Canada")
        expect(page).to have_select("Province", selected: "ON")

        check_out(product, address: { street: "568 Beatty St", city: "Vancouver", state: "BC", zip_code: "V6B 2L3" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(112_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(12_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end
    end

    context "when the product was from discover" do
      it "charges tax for Canada" do
        allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("192.206.151.131") # Ontario, Canada

        visit "/l/#{product.unique_permalink}?recommended_by=discover"
        expect(page).to have_text("$100")
        add_to_cart(product)

        expect(page).to have_select("Country", selected: "Canada")
        expect(page).to have_select("Province", selected: "ON")
        expect(page).to_not have_field "Business QST ID (optional)"

        select "QC", from: "Province"
        expect(page).to have_field "Business QST ID (optional)"
        check_out(product, zip_code: nil, credit_card: { number: "4000001240000000" }) do
          expect(page).to have_text("Subtotal US$100", normalize_ws: true)
          expect(page).to have_text("Tax US$14.98", normalize_ws: true)
        end

        purchase = Purchase.last
        expect(purchase.country).to eq("Canada")
        expect(purchase.state).to eq("QC")
        expect(purchase.ip_country).to eq("Canada")
        expect(purchase.card_country).to eq("CA")
        expect(purchase.total_transaction_cents).to eq(114_98)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(14_98)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "charges tax when Canada is selected but not detected from IP" do
        allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("67.183.58.7") # Washington, United States

        visit "/l/#{product.unique_permalink}?recommended_by=discover"
        expect(page).to have_text("$100")
        add_to_cart(product)

        select "Canada", from: "Country"
        check_out(product, zip_code: nil, credit_card: { number: "4000001240000000" }) do
          expect(page).to have_text("Subtotal US$100", normalize_ws: true)
          expect(page).to have_text("Tax US$5", normalize_ws: true)
        end

        purchase = Purchase.last
        expect(purchase.country).to eq("Canada")
        expect(purchase.state).to eq("AB")
        expect(purchase.ip_country).to eq("United States")
        expect(purchase.card_country).to eq("CA")
        expect(purchase.total_transaction_cents).to eq(105_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(5_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "allows the entry of QST ID and doesn't charge tax" do
        allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("104.163.219.131") # Quebec, Canada
        allow_any_instance_of(QstValidationService).to receive(:valid_qst?).and_return true

        visit "/l/#{product.unique_permalink}?recommended_by=discover"
        expect(page).to have_text("$100")
        add_to_cart(product)

        expect(page).to have_select("Country", selected: "Canada")
        expect(page).to have_select("Province", selected: "QC")

        check_out(product, qst_id: "1002092821TQ0001", zip_code: nil, credit_card: { number: "4000001240000000" }) do
          expect(page).to have_text("Subtotal US$100", normalize_ws: true)
          expect(page).to have_text("Total US$100", normalize_ws: true)
        end

        purchase = Purchase.last
        expect(purchase.country).to eq("Canada")
        expect(purchase.state).to eq("QC")
        expect(purchase.ip_country).to eq("Canada")
        expect(purchase.card_country).to eq("CA")
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
        expect(purchase.purchase_sales_tax_info.business_vat_id).to eq("1002092821TQ0001")

        # Check QST ID is present on the invoice as well

        visit purchase.receipt_url
        click_on("Generate")
        expect(page).to(have_text("1002092821TQ0001"))
      end

      it "charges tax and does not collect the QST ID if the QST ID is invalid" do
        allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("104.163.219.131") # Quebec, Canada

        visit "/l/#{product.unique_permalink}?recommended_by=discover"
        expect(page).to have_text("$100")
        add_to_cart(product)

        expect(page).to have_select("Country", selected: "Canada")
        expect(page).to have_select("Province", selected: "QC")

        check_out(product, qst_id: "NR00005576", zip_code: nil, credit_card: { number: "4000001240000000" }) do
          expect(page).to have_text("Subtotal US$100", normalize_ws: true)
          expect(page).to have_text("Tax US$14.98", normalize_ws: true)
        end

        purchase = Purchase.last
        expect(purchase.country).to eq("Canada")
        expect(purchase.state).to eq("QC")
        expect(purchase.ip_country).to eq("Canada")
        expect(purchase.card_country).to eq("CA")
        expect(purchase.total_transaction_cents).to eq(114_98)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(14_98)
        expect(purchase.was_purchase_taxable).to be(true)
        expect(purchase.purchase_sales_tax_info.business_vat_id).to eq(nil)
      end
    end
  end

  describe "country change scenarios" do
    before do
      @product = create(:product, price_cents: 100_00)
    end

    it "shows an error when elected country doesn't match EU card country or EU detected country" do
      create(:zip_tax_rate, country: "AT", zip_code: nil, state: nil, combined_rate: 0.20, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("85.127.28.23") # Austria

      visit "/l/#{@product.unique_permalink}"
      expect(page).to have_text("$100")
      add_to_cart(@product)

      expect(page).to have_select("Country", selected: "Austria")

      check_out(@product, country: "Mexico", zip_code: nil, credit_card: { number: "4000000400000008" },
                          error: "We could not validate the location you selected. Please review.")
    end

    it "allows the purchase when non-EU elected country matches the non-EU card country, but not the EU detected country" do
      create(:zip_tax_rate, country: "AT", zip_code: nil, state: nil, combined_rate: 0.20, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("85.127.28.23") # Austria

      visit "/l/#{@product.unique_permalink}"
      expect(page).to have_text("$100")
      add_to_cart(@product)

      expect(page).to have_select("Country", selected: "Austria")

      check_out(@product, country: "Mexico", zip_code: nil, credit_card: { number: "4000004840008001" })

      purchase = Purchase.last
      expect(purchase.country).to eq("Mexico")
      expect(purchase.ip_country).to eq("Austria")
      expect(purchase.card_country).to eq("MX")
      expect(purchase.total_transaction_cents).to eq(100_00)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(0)
      expect(purchase.was_purchase_taxable).to be(false)
    end

    it "clears the VAT and allows the purchase when non-EU elected country matches the non-EU card country, but not the EU detected country" do
      create(:zip_tax_rate, country: "AT", zip_code: nil, state: nil, combined_rate: 0.20, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("85.127.28.23") # Austria

      visit "/l/#{@product.unique_permalink}"
      expect(page).to have_text("$100")
      add_to_cart(@product)

      expect(page).to have_select("Country", selected: "Austria")

      fill_in("Your email address", with: "test@test.com")
      fill_cc_details

      expect(page).to have_text("VAT US$20", normalize_ws: true)

      fill_in("Business VAT ID (optional)", with: "NL860999063B01\t")

      expect(page).to_not have_text("VAT US$20", normalize_ws: true)

      select("Mexico", from: "Country")

      check_out(@product, zip_code: nil, credit_card: { number: "4000004840008001" })

      purchase = Purchase.last
      expect(purchase.country).to eq("Mexico")
      expect(purchase.ip_country).to eq("Austria")
      expect(purchase.card_country).to eq("MX")
      expect(purchase.total_transaction_cents).to eq(100_00)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(0)
      expect(purchase.was_purchase_taxable).to be(false)
    end

    it "allows the purchase when EU elected country matches the EU card country, but not the non-EU detected country" do
      create(:zip_tax_rate, country: "AT", zip_code: nil, state: nil, combined_rate: 0.20, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("189.144.240.120") # Mexico

      visit "/l/#{@product.unique_permalink}"
      expect(page).to have_text("$100")
      add_to_cart(@product)

      expect(page).to have_select("Country", selected: "Mexico")

      check_out(@product, country: "Austria", zip_code: nil, credit_card: { number: "4000000400000008" })

      purchase = Purchase.last
      expect(purchase.country).to eq("Austria")
      expect(purchase.ip_country).to eq("Mexico")
      expect(purchase.card_country).to eq("AT")
      expect(purchase.total_transaction_cents).to eq(120_00)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(20_00)
      expect(purchase.was_purchase_taxable).to be(true)
    end

    it "allows the purchase when elected country matches the detected country, but not the EU card country" do
      create(:zip_tax_rate, country: "AT", zip_code: nil, state: nil, combined_rate: 0.20, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("189.144.240.120") # Mexico

      visit "/l/#{@product.unique_permalink}"
      expect(page).to have_text("$100")
      add_to_cart(@product)

      expect(page).to have_select("Country", selected: "Mexico")

      check_out(@product, zip_code: nil, credit_card: { number: "4000000400000008" })

      purchase = Purchase.last
      expect(purchase.country).to eq("Mexico")
      expect(purchase.ip_country).to eq("Mexico")
      expect(purchase.card_country).to eq("AT")
      expect(purchase.total_transaction_cents).to eq(100_00)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(0)
      expect(purchase.was_purchase_taxable).to be(false)
    end

    it "allows the purchase when none of the mismatching countries are EU" do
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("189.144.240.120") # Mexico

      visit "/l/#{@product.unique_permalink}"
      expect(page).to have_text("$100")
      add_to_cart(@product)

      expect(page).to have_select("Country", selected: "Mexico")

      check_out(@product, zip_code: nil, country: "Haiti")

      purchase = Purchase.last
      expect(purchase.country).to eq("Haiti")
      expect(purchase.ip_country).to eq("Mexico")
      expect(purchase.card_country).to eq("US")
      expect(purchase.total_transaction_cents).to eq(100_00)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(0)
      expect(purchase.was_purchase_taxable).to be(false)
    end

    it "allows the purchase for a GeoIp2 country that isn't found in IsoCountryCodes" do
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("1.208.105.19") # South Korea
      allow_any_instance_of(Chargeable).to receive(:country) { "KR" }

      visit "/l/#{@product.unique_permalink}"
      expect(page).to have_text("$100")
      add_to_cart(@product)

      expect(page).to have_select("Country", selected: "South Korea")

      check_out(@product, zip_code: nil)

      purchase = Purchase.last
      expect(purchase.country).to eq("South Korea")
      expect(purchase.ip_country).to eq("South Korea")
      expect(purchase.card_country).to eq("KR")
      expect(purchase.total_transaction_cents).to eq(100_00)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(0)
      expect(purchase.was_purchase_taxable).to be(false)
    end

    it "allows the purchase and favors the GeoIp2 country name of Taiwan versus the IsoCountyCodes name of Taiwan, Province of China" do
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("1.174.208.0") # Taiwan

      visit "/l/#{@product.unique_permalink}"
      expect(page).to have_text("$100")
      add_to_cart(@product)

      expect(page).to have_select("Country", selected: "Taiwan")

      check_out(@product, zip_code: nil, credit_card: { number: "4000001580000008" })

      purchase = Purchase.last
      expect(purchase.country).to eq("Taiwan")
      expect(purchase.ip_country).to eq("Taiwan")
      expect(purchase.card_country).to eq("TW")
      expect(purchase.total_transaction_cents).to eq(100_00)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(0)
      expect(purchase.was_purchase_taxable).to be(false)
    end

    it "resets the tax and allows the purchase when the EU-elected country doesn't match the non-EU card country or non-EU detected country" do
      create(:zip_tax_rate, country: "AT", zip_code: nil, state: nil, combined_rate: 0.20, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("189.144.240.120") # Mexico

      visit "/l/#{@product.unique_permalink}"
      expect(page).to have_text("$100")
      add_to_cart(@product)

      expect(page).to have_select("Country", selected: "Mexico")

      check_out(@product, country: "Austria", zip_code: nil, credit_card: { number: "4000004840008001" })

      purchase = Purchase.last
      expect(purchase.country).to eq("Austria")
      expect(purchase.ip_country).to eq("Mexico")
      expect(purchase.card_country).to eq("MX")
      expect(purchase.total_transaction_cents).to eq(100_00)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(0)
      expect(purchase.was_purchase_taxable).to be(false)
    end
  end
end
