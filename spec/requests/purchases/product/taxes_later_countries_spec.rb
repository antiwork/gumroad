# frozen_string_literal: true

require("spec_helper")

describe("Product Page - Later country tax scenarios", type: :system, js: true) do
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

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Moscow", zip_code: "10000", state: "Moscow", country: "RU" }, credit_card: { number: "4000000360000006" })

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

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Riyadh", zip_code: "10000", state: "Riyadh", country: "SA" }, credit_card: { number: "4000000360000006" })

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

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Belgrade", zip_code: "10000", state: "Belgrade", country: "RS" }, credit_card: { number: "4000000360000006" })

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

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Seoul", zip_code: "10000", state: "Seoul", country: "KR" }, credit_card: { number: "4000000360000006" })

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

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Dar es Salaam", zip_code: "10000", state: "Dar es Salaam", country: "TZ" }, credit_card: { number: "4000000360000006" })

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

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Bangkok", zip_code: "10000", state: "Bangkok", country: "TH" }, credit_card: { number: "4000000360000006" })

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

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Istanbul", zip_code: "34000", state: "Istanbul", country: "TR" }, credit_card: { number: "4000000360000006" })

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

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Kyiv", zip_code: "01001", state: "Kyiv", country: "UA" }, credit_card: { number: "4000000360000006" })

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

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Tashkent", zip_code: "100000", state: "Tashkent", country: "UZ" }, credit_card: { number: "4000000360000006" })

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

        check_out(physical_product, address: { street: "Building 1234, Road 123, Block 123", city: "Hanoi", zip_code: "100000", state: "Hanoi", country: "VN" }, credit_card: { number: "4000000360000006" })

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

  describe "Canada Tax", taxjar: true, force_vcr_on: true do
    let (:product) { create(:product, price_cents: 100_00) }

    it "detects the province for Canada" do
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("184.65.213.114") # British Columbia, Canada

      visit "/l/#{product.unique_permalink}"
      expect(page).to have_text("$100")
      add_to_cart(product)

      expect(page).to have_select("Country", selected: "Canada")
      expect(page).to have_select("Province", selected: "BC")
      expect(page).to have_text("Total US$112", normalize_ws: true)

      check_out(product, zip_code: nil, credit_card: { number: "4000001240000000" })

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
      expect(page).to have_text("Total US$113", normalize_ws: true)

      select "QC", from: "Province"
      page.execute_script("document.activeElement.blur()")
      expect(page).to have_text("Total US$114.98", normalize_ws: true)

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

    context "when the product is physical" do
      let(:product) { create(:physical_product, price_cents: 100_00) }

      it "allows the customer to select province for a physical product to Canada" do
        allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("192.206.151.131") # Ontario, Canada

        visit "/l/#{product.unique_permalink}"
        expect(page).to have_text("$100")
        add_to_cart(product)

        expect(page).to have_select("Country", selected: "Canada")
        expect(page).to have_select("Province", selected: "ON")
        expect(page).to have_text("Total US$113", normalize_ws: true)

        select "BC", from: "Province"
        page.execute_script("document.activeElement.blur()")
        expect(page).to have_text("Total US$112", normalize_ws: true)

        check_out(product, address: { street: "568 Beatty St", city: "Vancouver", state: "BC", zip_code: "V6B 2L3" }) do
          expect(page).to have_text("Total US$112", normalize_ws: true)
        end

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
        expect(page).to_not have_field("Business QST ID (optional)", wait: 10)

        select "QC", from: "Province"
        page.execute_script("document.activeElement.blur()")
        expect(page).to have_field("Business QST ID (optional)", wait: 10)
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

      it "charges tax when Canada is selected but not detected from IP" do
        allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("67.183.58.7") # Washington, United States

        visit "/l/#{product.unique_permalink}?recommended_by=discover"
        expect(page).to have_text("$100")
        add_to_cart(product)

        select "Canada", from: "Country"
        expect(page).to have_text("Total US$105", normalize_ws: true, wait: 10)
        check_out(product, zip_code: nil, credit_card: { number: "4000001240000000" })

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

        expect(page).to have_field("Business QST ID (optional)", wait: 10)
        check_out(product, qst_id: "1002092821TQ0001", zip_code: nil, credit_card: { number: "4000001240000000" })

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

        expect(page).to have_field("Business QST ID (optional)", wait: 10)
        check_out(product, qst_id: "NR00005576", zip_code: nil, credit_card: { number: "4000001240000000" })

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

      # Stripe may or may not 3DS-challenge this Mexico card; these specs are about tax, not
      # authentication, so clear the challenge only if it shows up.
      check_out(@product, country: "Mexico", zip_code: nil, credit_card: { number: "4000004840008001" }, sca: :if_challenged)

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

      fill_in("Email address", with: "test@test.com")
      fill_in_credit_card

      fill_in("Business VAT ID (optional)", with: "NL860999063B01\t")

      select("Mexico", from: "Country")

      # Stripe may or may not 3DS-challenge this Mexico card; these specs are about tax, not
      # authentication, so clear the challenge only if it shows up.
      check_out(@product, zip_code: nil, credit_card: { number: "4000004840008001" }, sca: :if_challenged)

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

    it "trusts the EU-elected country and charges VAT when the non-EU card country and non-EU detected country don't contradict it" do
      create(:zip_tax_rate, country: "AT", zip_code: nil, state: nil, combined_rate: 0.20, is_seller_responsible: false)
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("189.144.240.120") # Mexico

      visit "/l/#{@product.unique_permalink}"
      expect(page).to have_text("$100")
      add_to_cart(@product)

      expect(page).to have_select("Country", selected: "Mexico")

      # Stripe may or may not 3DS-challenge this Mexico card; these specs are about tax, not
      # authentication, so clear the challenge only if it shows up.
      check_out(@product, country: "Austria", zip_code: nil, credit_card: { number: "4000004840008001" }, sca: :if_challenged)

      purchase = Purchase.last
      expect(purchase.country).to eq("Austria")
      expect(purchase.ip_country).to eq("Mexico")
      expect(purchase.card_country).to eq("MX")
      expect(purchase.total_transaction_cents).to eq(120_00)
      expect(purchase.price_cents).to eq(100_00)
      expect(purchase.tax_cents).to eq(0)
      expect(purchase.gumroad_tax_cents).to eq(20_00)
      expect(purchase.was_purchase_taxable).to be(true)
    end
  end
end
