# frozen_string_literal: true

require("spec_helper")

describe("Product Page - Collect-tax country scenarios", type: :system, js: true) do
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

        check_out(@product, zip_code: nil, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(118_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(18_00)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "charges a whole-cent tax amount when the rate produces fractional cents, matching the quoted total" do
        # Regression coverage for the buyer-currency "total mismatch" incident: 18% GST on a
        # $9.99 product is 179.82 fractional cents. The checkout quote rounded the summed
        # total (tax 180 => total 1179) while charge-time persistence truncated the tax into
        # the integer column (179 => total 1178), so the total charged never matched the
        # total quoted. With rounding at the calculator boundary, both the displayed checkout
        # total and the persisted purchase must agree on 180 cents of tax / a 1179-cent total.
        # This spec fails if the calculator's rounding is reverted (tax truncates to 179).
        fractional_product = create(:product, user: @product.user, price_cents: 9_99)

        visit "/l/#{fractional_product.unique_permalink}"
        expect(page).to have_text("$9.99")
        add_to_cart(fractional_product)

        check_out(fractional_product, zip_code: nil, credit_card: { number: "4000000360000006" }) do
          expect(page).to have_text("GST", normalize_ws: true)
          expect(page).to have_text("Total US$11.79", normalize_ws: true)
        end

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(11_79)
        expect(purchase.price_cents).to eq(9_99)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(1_80)
        expect(purchase.was_purchase_taxable).to be(true)
      end

      it "allows entry of the Tax ID and doesn't charge tax", :stub_tax_id_validation do
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

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Manama", zip_code: "12345", state: "BH", country: "BH" }, credit_card: { number: "4000000360000006" })

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

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Minsk", zip_code: "220000", state: "BY", country: "BY" }, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax", :stub_tax_id_validation do
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

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Santiago", zip_code: "7500000", state: "CL", country: "CL" }, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax", :stub_tax_id_validation do
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

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Bogota, D.C.", zip_code: "110111", state: "CO", country: "CO" }, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax", :stub_tax_id_validation do
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

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "San José", zip_code: "110111", state: "CR", country: "CR" }, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax", :stub_tax_id_validation do
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

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Quito", zip_code: "170101", state: "EC", country: "EC" }, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax", :stub_tax_id_validation do
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

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Cairo", zip_code: "11511", state: "CA", country: "EG" }, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax", :stub_tax_id_validation do
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

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Tbilisi", zip_code: "0100", state: "TB", country: "GE" }, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax", :stub_tax_id_validation do
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

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Almaty", zip_code: "050000", state: "AL", country: "KZ" }, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax", :stub_tax_id_validation do
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

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Nairobi", zip_code: "00100", state: "NA", country: "KE" }, credit_card: { number: "4000000360000006" })

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

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Kuala Lumpur", zip_code: "50000", state: "WP", country: "MY" }, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax", :stub_tax_id_validation do
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
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("187.189.0.1") # Mexico

      @product = create(:product, price_cents: 100_00)

      create(:user_compliance_info_empty, user: @product.user,
                                          first_name: "edgar", last_name: "gumstein", street_address: "123 main", city: "sf", state: "ca",
                                          zip_code: "94107", country: Compliance::Countries::USA.common_name)

      @product.save!
    end

    it "does not apply tax in Mexico" do
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

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Chisinau", zip_code: "MD-2001", state: "Chisinau", country: "MD" }, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax", :stub_tax_id_validation do
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

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Rabat", zip_code: "10000", state: "Rabat", country: "MA" }, credit_card: { number: "4000000360000006" })

        purchase = Purchase.last
        expect(purchase.total_transaction_cents).to eq(100_00)
        expect(purchase.price_cents).to eq(100_00)
        expect(purchase.tax_cents).to eq(0)
        expect(purchase.gumroad_tax_cents).to eq(0)
        expect(purchase.was_purchase_taxable).to be(false)
      end

      it "allows entry of the Tax ID and doesn't charge tax", :stub_tax_id_validation do
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

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Lagos", zip_code: "10000", state: "Lagos", country: "NG" }, credit_card: { number: "4000000360000006" })

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

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Muscat", zip_code: "10000", state: "Muscat", country: "OM" }, credit_card: { number: "4000000360000006" })

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
end
