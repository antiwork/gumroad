# frozen_string_literal: true

require("spec_helper")

describe("Product Page - Tax Scenarios", type: :system, js: true) do
  def set_zip_code_via_js(zip_code)
    zip_field = find_field("ZIP code")
    page.execute_script(<<~JS, zip_field)
      var el = arguments[0];
      var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
      setter.call(el, '');
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
      el.dispatchEvent(new Event('blur', { bubbles: true }));
    JS
    sleep 0.1
    page.execute_script(<<~JS, zip_field, zip_code)
      var el = arguments[0];
      var zip = arguments[1];
      var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
      setter.call(el, zip);
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
      el.dispatchEvent(new Event('blur', { bubbles: true }));
    JS
    # Wait for the debounced surcharge recalculation to complete
    wait_for_checkout_surcharges_loaded
  end

  describe "sales tax", shipping: true, force_vcr_on: true do
    before do
      @creator = create(:user_with_compliance_info)

      @product = create(:physical_product, user: @creator, require_shipping: true, price_cents: 500_00)
    end

    it "calls the tax endpoint for a real zip code that doesn't show in the enterprise zip codes database" do
      visit("/l/#{@product.unique_permalink}")
      add_to_cart(@product)
      check_out(@product, address: { street: "3029 W Sherman Rd", city: "San Tan Valley", state: "AZ", zip_code: "85144" }) do
        expect(page).to have_select("State", selected: "AZ")
        set_zip_code_via_js("85144")
        expect(page).to have_text("Sales tax", normalize_ws: true)
        expect(page).to have_text("Total US$553.50", normalize_ws: true)
      end

      expect(page).to have_text("Your purchase was successful!")

      expect(Purchase.successful.count).to eq 1

      new_purchase = Purchase.last
      expect(new_purchase.link_id).to eq(@product.id)
      expect(new_purchase.price_cents).to eq(500_00)
      expect(new_purchase.total_transaction_cents).to eq(55_350)
      expect(new_purchase.fee_cents).to eq(65_30) # 500_00 * 0.129 + 50c + 30c
      expect(new_purchase.tax_cents).to eq(0)
      expect(new_purchase.gumroad_tax_cents).to eq(53_50)
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
          set_zip_code_via_js("85144")
          expect(page).to have_text("Total US$555.16", normalize_ws: true)
        end

        expect(page).to have_text("Your purchase was successful!")

        expect(Purchase.successful.count).to eq 1

        new_purchase = Purchase.last
        expect(new_purchase.link_id).to eq(@product.id)
        expect(new_purchase.price_cents).to eq(501_50)
        expect(new_purchase.total_transaction_cents).to eq(555_16)
        expect(new_purchase.fee_cents).to eq(65_49) # 535_10 * 0.129 + 50c + 30c
        expect(new_purchase.gumroad_tax_cents).to eq(53_66)
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
          set_zip_code_via_js("85144")
          expect(page).to have_text("Total US$442.80", normalize_ws: true)
        end

        expect(page).to have_text("Your purchase was successful!")

        expect(Purchase.successful.count).to eq 1

        new_purchase = Purchase.last
        expect(new_purchase.link_id).to eq(@product.id)
        expect(new_purchase.price_cents).to eq(400_00)
        expect(new_purchase.total_transaction_cents).to eq(442_80)
        expect(new_purchase.fee_cents).to eq(52_40) # 434_50 * 0.129 + 50c + 30c
        expect(new_purchase.gumroad_tax_cents).to eq(42_80)
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
        set_zip_code_via_js("85144")
        expect(page).to have_text("Subtotal US$500", normalize_ws: true)
        expect(page).to_not have_text("Tip US$", normalize_ws: true)
        expect(page).to have_text("Sales tax US$53.50", normalize_ws: true)
        expect(page).to have_text("Total US$553.50", normalize_ws: true)

        choose "20%"
        expect(page).to have_text("Subtotal US$600", normalize_ws: true)
        expect(page).to have_text("Add a tip? US$100", normalize_ws: true)
        expect(page).to have_text("Sales tax US$58.85", normalize_ws: true)
        expect(page).to have_text("Total US$658.85", normalize_ws: true)

        click_on "Pay"
        expect(page).to have_alert(text: "Your purchase was successful!")

        purchase = Purchase.last
        expect(purchase.link_id).to eq(@product.id)
        expect(purchase.price_cents).to eq(600_00)
        expect(purchase.total_transaction_cents).to eq(658_85)
        expect(purchase.fee_cents).to eq(78_20) # 600_00 * 0.129 + 50c + 30c
        expect(purchase.gumroad_tax_cents).to eq(58_85)
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
        expect(purchase.tip.value_cents).to eq(100_00)
      end
    end
  end

  describe "US sales tax", taxjar: true, force_vcr_on: true do
    it "calculates and charges sales tax when WI customer makes purchase" do
      product = create(:product, price_cents: 100_00)
      visit "/l/#{product.unique_permalink}"
      expect(page).to have_text("$100")

      add_to_cart(product)
      check_out(product, zip_code: "53703") do
        set_zip_code_via_js("53703")
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
        set_zip_code_via_js("53703")
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
        set_zip_code_via_js("98121")
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
        set_zip_code_via_js("98121")
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
        set_zip_code_via_js("53703")
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
        set_zip_code_via_js("98121")
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

    it "allows entry of VAT ID and doesn't charge VAT", :stub_tax_id_validation do
      visit "/l/#{@vat_link.unique_permalink}"
      expect(page).to have_selector("[itemprop='offers']", text: "$100")

      add_to_cart(@vat_link)

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

      it "allows entry of VAT ID and doesn't charge VAT", :stub_tax_id_validation do
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

    it "does not charge VAT for a physical product shipped to the EU" do
      product = create(:physical_product, price_cents: 100_00)
      visit "/l/#{product.unique_permalink}"
      expect(page).to have_text("$100")

      add_to_cart(product)
      check_out(product, address: { street: "Via del Governo Vecchio, 87", city: "Rome", state: "Latium", zip_code: "00186" })

      purchase = Purchase.last
      expect(purchase.total_transaction_cents).to eq(100_00)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(0)
      expect(purchase.was_purchase_taxable).to be(false)
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
      check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

      purchase = Purchase.last
      expect(purchase.total_transaction_cents).to eq(110_00)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(10_00)
      expect(purchase.was_purchase_taxable).to be(true)
    end

    it "allows entry of ABN ID and doesn't charge GST", :stub_tax_id_validation do
      visit "/l/#{@product.unique_permalink}"
      expect(page).to have_selector("[itemprop='offers']", text: "$100")

      add_to_cart(@product)
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

      check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

      purchase = Purchase.last
      expect(purchase.total_transaction_cents).to eq(100_00)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(0)
      expect(purchase.was_purchase_taxable).to be(false)
    end

    it "allows entry of MVA ID and doesn't charge tax", :stub_tax_id_validation do
      visit "/l/#{@product.unique_permalink}"
      expect(page).to have_text("$100")
      add_to_cart(@product)

      check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" }, mva_id: "977074010MVA") do
        expect(page).not_to have_text("VAT US$", normalize_ws: true)
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

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(111_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(11_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "allows entry of the Tax ID and doesn't charge tax", :stub_tax_id_validation do
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

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(110_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(10_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "allows entry of the Tax ID and doesn't charge tax", :stub_tax_id_validation do
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

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(115_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(15_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "allows entry of the Tax ID and doesn't charge tax", :stub_tax_id_validation do
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

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(115_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(15_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "allows entry of the Tax ID and doesn't charge tax", :stub_tax_id_validation do
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

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(102_60)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(2_60)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "allows entry of the Tax ID and doesn't charge tax", :stub_tax_id_validation do
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

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(105_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(5_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "allows entry of the Tax ID and doesn't charge tax", :stub_tax_id_validation do
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
end
