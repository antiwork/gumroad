# frozen_string_literal: true

require "spec_helper"

describe SalesTaxCalculator do
  describe "input validation" do
    it "only accepts a hash for buyer location info" do
      expect do
        SalesTaxCalculator.new(product: create(:product),
                               price_cents: 100,
                               buyer_location: 123_456).calculate
      end.to raise_error(SalesTaxCalculatorValidationError, "Buyer Location should be a Hash")
    end

    it "only accepts an integer for base price in cents" do
      expect do
        SalesTaxCalculator.new(product: create(:product),
                               price_cents: 100.0,
                               buyer_location: { postal_code: "12345", country: "US" }).calculate
      end.to raise_error(SalesTaxCalculatorValidationError, "Price (cents) should be an Integer")
    end

    it "requires product to be an instance of the class" do
      expect do
        SalesTaxCalculator.new(product: [],
                               price_cents: 100,
                               buyer_location: { postal_code: "12345", country: "US" },).calculate
      end.to raise_error(SalesTaxCalculatorValidationError, "Product should be a Link instance")
    end
  end

  describe "#calculate" do
    before(:each) do
      @seller = create(:user)
    end

    it "returns zero tax if the base price is 0" do
      sales_tax = SalesTaxCalculator.new(product: create(:product, user: @seller),
                                         price_cents: 0,
                                         buyer_location: { postal_code: "12345", country: "US" }).calculate

      compare_calculations(expected: SalesTaxCalculation.zero_tax(0), actual: sales_tax)
    end

    it "returns zero tax if product is physical and in the EU" do
      create(:zip_tax_rate, country: "DE", zip_code: nil, state: nil)

      sales_tax = SalesTaxCalculator.new(product: create(:physical_product, user: @seller),
                                         price_cents: 100,
                                         buyer_location: { country: "DE" }).calculate

      compare_calculations(expected: SalesTaxCalculation.zero_tax(100), actual: sales_tax)
    end

    it "ignores seller taxable regions and overrides inclusive taxation when applicable (non-US)" do
      expected_tax_rate = create(:zip_tax_rate, country: "ES", zip_code: nil, state: nil, combined_rate: 0.21, is_seller_responsible: false)

      expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                   tax_cents: 21,
                                                   zip_tax_rate: expected_tax_rate)

      actual_sales_tax = SalesTaxCalculator.new(product: create(:product, user: @seller),
                                                price_cents: 100,
                                                buyer_location: { country: "ES" },).calculate

      compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
    end

    describe "with TaxJar", :vcr do
      before do
        @creator = create(:user_with_compliance_info)

        @product = create(:physical_product, user: @creator, require_shipping: true, price_cents: 1000)
        @product.shipping_destinations << ShippingDestination.new(country_code: "US", one_item_rate_cents: 100, multiple_items_rate_cents: 200)
        @product.save!
      end

      it "calculates with TaxJar for a state where shipping is taxable" do
        expected_rate = 0.1025.to_d
        expected_tax_cents = ((@product.price_cents + @product.shipping_destinations.last.one_item_rate_cents) * expected_rate).round.to_d

        expected_calculation = SalesTaxCalculation.new(price_cents: @product.price_cents,
                                                       tax_cents: expected_tax_cents,
                                                       zip_tax_rate: nil,
                                                       used_taxjar: true,
                                                       taxjar_info: {
                                                         combined_tax_rate: expected_rate,
                                                         state_tax_rate: 0.065,
                                                         county_tax_rate: 0.003,
                                                         city_tax_rate: 0.0115,
                                                         gst_tax_rate: nil,
                                                         pst_tax_rate: nil,
                                                         qst_tax_rate: nil,
                                                         jurisdiction_state: "WA",
                                                         jurisdiction_county: "KING",
                                                         jurisdiction_city: "SEATTLE",
                                                       })

        calculation = SalesTaxCalculator.new(product: @product,
                                             price_cents: @product.price_cents,
                                             shipping_cents: @product.shipping_destinations.last.one_item_rate_cents,
                                             quantity: 1,
                                             buyer_location: { postal_code: "98121", country: "US" }).calculate

        compare_calculations(expected: expected_calculation, actual: calculation)
      end

      it "does not call TaxJar and returns zero tax when customer zip code is invalid" do
        expect_any_instance_of(TaxjarApi).to_not receive(:calculate_tax_for_order)

        calculation = SalesTaxCalculator.new(product: @product,
                                             price_cents: @product.price_cents,
                                             shipping_cents: @product.shipping_destinations.last.one_item_rate_cents,
                                             quantity: 1,
                                             buyer_location: { postal_code: "invalidzip", country: "US" }).calculate

        compare_calculations(expected: SalesTaxCalculation.zero_tax(@product.price_cents), actual: calculation)
      end

      it "does not call TaxJar and returns zero tax when creator doesn't have nexus in the state of the customer zip" do
        expect_any_instance_of(TaxjarApi).to_not receive(:calculate_tax_for_order)

        calculation = SalesTaxCalculator.new(product: @product,
                                             price_cents: @product.price_cents,
                                             shipping_cents: @product.shipping_destinations.last.one_item_rate_cents,
                                             quantity: 1,
                                             buyer_location: { postal_code: "94107", country: "US" }).calculate

        compare_calculations(expected: SalesTaxCalculation.zero_tax(@product.price_cents), actual: calculation)
      end

      it "does not charge tax for purchases in situations where Gumroad is not responsible for tax" do
        actual_sales_tax = SalesTaxCalculator.new(product: create(:product, user: @seller),
                                                  price_cents: 100,
                                                  buyer_location: { country: "US", postal_code: "94104" },
                                                  from_discover: true).calculate

        compare_calculations(expected: SalesTaxCalculation.zero_tax(100), actual: actual_sales_tax)
      end

      shared_examples "valid tax calculation for a US state" do |state, county, city, zip_code, combined_rate, state_rate, county_rate, city_rate|
        it "performs a valid tax calculation for #{state} when the sale is recommended" do
          expected_tax_amount = (100 * combined_rate).round

          expected_sales_tax = SalesTaxCalculation.new(
            price_cents: 100,
            tax_cents: expected_tax_amount,
            zip_tax_rate: nil,
            used_taxjar: true,
            taxjar_info: {
              combined_tax_rate: combined_rate,
              state_tax_rate: state_rate,
              county_tax_rate: county_rate,
              city_tax_rate: city_rate,
              gst_tax_rate: nil,
              pst_tax_rate: nil,
              qst_tax_rate: nil,
              jurisdiction_state: state,
              jurisdiction_county: county,
              jurisdiction_city: city,
            }
          )

          actual_sales_tax = SalesTaxCalculator.new(
            product: create(:product, user: @seller),
            price_cents: 100,
            buyer_location: { country: "US", postal_code: zip_code },
            from_discover: true
          ).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      include_examples "valid tax calculation for a US state", "WI", "SHEBOYGAN", "WALDO", "53093", 0.055, 0.05, 0.005, 0.0
      include_examples "valid tax calculation for a US state", "WA", "FRANKLIN", nil, "99301", 0.081, 0.065, 0.006, 0.01
      include_examples "valid tax calculation for a US state", "NC", "WAKE", "CARY", "27513", 0.0725, 0.0475, 0.02, 0.0
      include_examples "valid tax calculation for a US state", "NJ", "ESSEX", "NEWARK", "07101", 0.06625, 0.06625, 0.0, 0.0
      include_examples "valid tax calculation for a US state", "OH", "LICKING", "BLACKLICK", "43004", 0.0725, 0.0575, 0.015, 0.0
      include_examples "valid tax calculation for a US state", "PA", "PHILADELPHIA", "PHILADELPHIA", "19019", 0.06, 0.06, 0.0, 0.0
      include_examples "valid tax calculation for a US state", "AR", "PULASKI", "LITTLE ROCK", "72201", 0.075, 0.065, 0.01, 0.0
      include_examples "valid tax calculation for a US state", "AZ", "MARICOPA", nil, "85001", 0.063, 0.056, 0.007, 0.0
      include_examples "valid tax calculation for a US state", "CO", "DENVER", "DENVER", "80202", 0.04, 0.029, 0.0, 0.0
      include_examples "valid tax calculation for a US state", "CT", "HARTFORD", "CENTRAL", "06103", 0.0635, 0.0635, 0.0, 0.0
      include_examples "valid tax calculation for a US state", "DC", "DISTRICT OF COLUMBIA", "WASHINGTON", "20001", 0.06, 0.06, 0.0, 0.0
      include_examples "valid tax calculation for a US state", "GA", "FULTON", "ATLANTA", "30301", 0.0, 0.0, 0.0, 0.0
      include_examples "valid tax calculation for a US state", "HI", "HONOLULU", "URBAN HONOLULU", "96813", 0.045, 0.04, 0.005, 0.0
      include_examples "valid tax calculation for a US state", "IL", "COOK", "CHICAGO", "60601", 0.0, 0.0, 0.0, 0.0
      include_examples "valid tax calculation for a US state", "IN", "MARION", "INDIANAPOLIS", "46201", 0.07, 0.07, 0.0, 0.0
      include_examples "valid tax calculation for a US state", "KY", "JEFFERSON", "LOUISVILLE", "40201", 0.06, 0.06, 0.0, 0.0
      include_examples "valid tax calculation for a US state", "LA", "ORLEANS", "NEW ORLEANS", "70112", 0.0945, 0.0445, 0.0, 0.0
      include_examples "valid tax calculation for a US state", "MA", "SUFFOLK", "BOSTON", "02108", 0.0, 0.0, 0.0, 0.0
      include_examples "valid tax calculation for a US state", "MD", "BALTIMORE CITY", "BALTIMORE", "21201", 0.0, 0.0, 0.0, 0.0
      include_examples "valid tax calculation for a US state", "MN", "HENNEPIN", "MINNEAPOLIS", "55401", 0.09025, 0.06875, 0.0015, 0.005
      include_examples "valid tax calculation for a US state", "NE", "DOUGLAS", "OMAHA", "68102", 0.07, 0.055, 0.0, 0.015
      include_examples "valid tax calculation for a US state", "NY", "NEW YORK", "NEW YORK", "10001", 0.0, 0.0, 0.0, 0.0
      include_examples "valid tax calculation for a US state", "RI", "PROVIDENCE", "PROVIDENCE", "02903", 0.07, 0.07, 0.0, 0.0
      include_examples "valid tax calculation for a US state", "SD", "MINNEHAHA", "SIOUX FALLS", "57101", 0.062, 0.042, 0.0, 0.02
      include_examples "valid tax calculation for a US state", "TN", "DAVIDSON", "NASHVILLE-DAVIDSON METROPOLITAN GOVERNMENT (BALANCE)", "37201", 0.1, 0.07, 0.025, 0.0
      include_examples "valid tax calculation for a US state", "TX", "TRAVIS", "AUSTIN", "78701", 0.0825, 0.0625, 0.00, 0.01
      include_examples "valid tax calculation for a US state", "UT", "SALT LAKE", "SALT LAKE CITY", "84101", 0.0775, 0.0485, 0.024, 0.005
      include_examples "valid tax calculation for a US state", "VT", "CHITTENDEN", "BURLINGTON", "05401", 0.07, 0.06, 0.0, 0.01

      shared_examples "valid tax calculation for US state" do |state, county, city, zip_code, combined_rate, state_rate, county_rate, city_rate|
        it "performs a valid tax calculation for #{state} when the sale is not recommended" do
          expected_tax_amount = (100 * combined_rate).round

          expected_sales_tax = SalesTaxCalculation.new(
            price_cents: 100,
            tax_cents: expected_tax_amount,
            zip_tax_rate: nil,
            used_taxjar: true,
            taxjar_info: {
              combined_tax_rate: combined_rate,
              state_tax_rate: state_rate,
              county_tax_rate: county_rate,
              city_tax_rate: city_rate,
              gst_tax_rate: nil,
              pst_tax_rate: nil,
              qst_tax_rate: nil,
              jurisdiction_state: state,
              jurisdiction_county: county,
              jurisdiction_city: city,
            }
          )

          actual_sales_tax = SalesTaxCalculator.new(
            product: create(:product, user: @seller),
            price_cents: 100,
            buyer_location: { country: "US", postal_code: zip_code },
            from_discover: false
          ).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      include_examples "valid tax calculation for US state", "WI", "SHEBOYGAN", "WALDO", "53093", 0.055, 0.05, 0.005, 0.0
      include_examples "valid tax calculation for US state", "WA", "FRANKLIN", nil, "99301", 0.081, 0.065, 0.006, 0.01
      include_examples "valid tax calculation for US state", "NC", "WAKE", "CARY", "27513", 0.0725, 0.0475, 0.02, 0.0
      include_examples "valid tax calculation for US state", "NJ", "HUDSON", "JERSEY CITY", "07302", 0.06625, 0.06625, 0.0, 0.0
      include_examples "valid tax calculation for US state", "OH", "LICKING", "BLACKLICK", "43004", 0.0725, 0.0575, 0.015, 0.0
      include_examples "valid tax calculation for US state", "PA", "PHILADELPHIA", "PHILADELPHIA", "19019", 0.06, 0.06, 0.0, 0.0
      include_examples "valid tax calculation for US state", "AR", "PULASKI", "LITTLE ROCK", "72201", 0.075, 0.065, 0.01, 0.0
      include_examples "valid tax calculation for US state", "AZ", "MARICOPA", nil, "85001", 0.063, 0.056, 0.007, 0.0
      include_examples "valid tax calculation for US state", "CO", "DENVER", "DENVER", "80202", 0.04, 0.029, 0.0, 0.0
      include_examples "valid tax calculation for US state", "CT", "HARTFORD", "CENTRAL", "06103", 0.0635, 0.0635, 0.0, 0.0
      include_examples "valid tax calculation for US state", "DC", "DISTRICT OF COLUMBIA", "WASHINGTON", "20001", 0.06, 0.06, 0.0, 0.0
      include_examples "valid tax calculation for US state", "GA", "FULTON", "ATLANTA", "30301", 0.0, 0.0, 0.0, 0.0
      include_examples "valid tax calculation for US state", "HI", "HONOLULU", "URBAN HONOLULU", "96813", 0.045, 0.04, 0.005, 0.0
      include_examples "valid tax calculation for US state", "IL", "COOK", "CHICAGO", "60601", 0.0, 0.0, 0.0, 0.0
      include_examples "valid tax calculation for US state", "IN", "MARION", "INDIANAPOLIS", "46201", 0.07, 0.07, 0.0, 0.0
      include_examples "valid tax calculation for US state", "KY", "JEFFERSON", "LOUISVILLE", "40201", 0.06, 0.06, 0.0, 0.0
      include_examples "valid tax calculation for US state", "LA", "ORLEANS", "NEW ORLEANS", "70112", 0.1, 0.05, 0.0, 0.0
      include_examples "valid tax calculation for US state", "MA", "SUFFOLK", "BOSTON", "02108", 0.0, 0.0, 0.0, 0.0
      include_examples "valid tax calculation for US state", "MD", "BALTIMORE CITY", "BALTIMORE", "21201", 0.0, 0.0, 0.0, 0.0
      include_examples "valid tax calculation for US state", "MN", "HENNEPIN", "MINNEAPOLIS", "55401", 0.09025, 0.06875, 0.0015, 0.005
      include_examples "valid tax calculation for US state", "NE", "DOUGLAS", "OMAHA", "68102", 0.07, 0.055, 0.0, 0.015
      include_examples "valid tax calculation for US state", "NY", "NEW YORK", "NEW YORK", "10001", 0.0, 0.0, 0.0, 0.0
      include_examples "valid tax calculation for US state", "RI", "PROVIDENCE", "PROVIDENCE", "02903", 0.07, 0.07, 0.0, 0.0
      include_examples "valid tax calculation for US state", "SD", "MINNEHAHA", "SIOUX FALLS", "57101", 0.062, 0.042, 0.0, 0.02
      include_examples "valid tax calculation for US state", "TN", "DAVIDSON", "NASHVILLE-DAVIDSON METROPOLITAN GOVERNMENT (BALANCE)", "37201", 0.1, 0.07, 0.025, 0.0
      include_examples "valid tax calculation for US state", "TX", "TRAVIS", "AUSTIN", "78701", 0.0825, 0.0625, 0.00, 0.01
      include_examples "valid tax calculation for US state", "UT", "SALT LAKE", "SALT LAKE CITY", "84101", 0.0825, 0.0485, 0.024, 0.01
      include_examples "valid tax calculation for US state", "VT", "CHITTENDEN", "BURLINGTON", "05401", 0.07, 0.06, 0.0, 0.01

      it "performs a valid tax calculation for Ontario Canada purchases" do
        expected_tax_amount = 13

        expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                     tax_cents: expected_tax_amount,
                                                     zip_tax_rate: nil,
                                                     used_taxjar: true,
                                                     taxjar_info: {
                                                       combined_tax_rate: 0.13,
                                                       state_tax_rate: nil,
                                                       county_tax_rate: nil,
                                                       city_tax_rate: nil,
                                                       gst_tax_rate: 0.05,
                                                       pst_tax_rate: 0.08,
                                                       qst_tax_rate: 0.0,
                                                       jurisdiction_state: "ON",
                                                       jurisdiction_county: nil,
                                                       jurisdiction_city: nil,
                                                     })

        actual_sales_tax = SalesTaxCalculator.new(product: create(:product, user: @seller),
                                                  price_cents: 100,
                                                  buyer_location: { country: "CA", state: "ON" }).calculate

        compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
      end

      it "does not assess Canada Tax when a valid QST ID is provided on a sale into Quebec" do
        expected_sales_tax = SalesTaxCalculation.zero_business_vat(100)

        actual_sales_tax = SalesTaxCalculator.new(product: create(:product, user: @seller),
                                                  price_cents: 100,
                                                  buyer_location: { country: "CA", state: QUEBEC },
                                                  from_discover: true,
                                                  buyer_vat_id: "1002092821TQ0001").calculate

        compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
      end
    end

    describe "AU GST" do
      it "assesses GST in Australia" do
        product = create(:product, user: @seller)
        expected_tax_rate = create(:zip_tax_rate, country: "AU", state: nil, zip_code: nil, combined_rate: 0.10, is_seller_responsible: false)

        expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                     tax_cents: 10,
                                                     zip_tax_rate: expected_tax_rate)

        actual_sales_tax = SalesTaxCalculator.new(product:,
                                                  price_cents: 100,
                                                  buyer_location: { country: "AU" }).calculate

        compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
      end

      it "assesses GST for direct to customer sales in Australia" do
        product = create(:physical_product, user: @seller)
        expected_tax_rate = create(:zip_tax_rate, country: "AU", state: nil, zip_code: nil, combined_rate: 0.10, is_seller_responsible: false)

        expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                     tax_cents: 10,
                                                     zip_tax_rate: expected_tax_rate)

        actual_sales_tax = SalesTaxCalculator.new(product:,
                                                  price_cents: 100,
                                                  buyer_location: { country: "AU" }).calculate

        compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
      end
    end

    describe "Singapore GST" do
      before do
        @tax_rate_2023 = create(:zip_tax_rate, country: "SG", state: nil, zip_code: nil, combined_rate: 0.08, is_seller_responsible: false, applicable_years: [2023])
        @tax_rate_2024 = create(:zip_tax_rate, country: "SG", state: nil, zip_code: nil, combined_rate: 0.09, is_seller_responsible: false, applicable_years: [2024])
      end

      it "assesses GST in Singapore in 2023" do
        travel_to(Time.find_zone("UTC").local(2023, 4, 1)) do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 8,
                                                       zip_tax_rate: @tax_rate_2023)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "SG" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      it "assesses GST in Singapore in 2024" do
        travel_to(Time.find_zone("UTC").local(2024, 4, 1)) do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 9,
                                                       zip_tax_rate: @tax_rate_2024)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "SG" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      it "assesses GST in Singapore after 2024 even if we did not add a tax rate for that year" do
        travel_to(Time.find_zone("UTC").local(2025, 4, 1)) do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 9,
                                                       zip_tax_rate: @tax_rate_2024)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "SG" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      it "assesses GST for direct to customer sales in Singapore" do
        product = create(:physical_product, user: @seller)

        expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                     tax_cents: 9,
                                                     zip_tax_rate: @tax_rate_2024)

        actual_sales_tax = SalesTaxCalculator.new(product:,
                                                  price_cents: 100,
                                                  buyer_location: { country: "SG" }).calculate

        compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
      end
    end

    describe "Norway VAT" do
      it "assesses VAT in Norway" do
        product = create(:product, user: @seller)
        expected_tax_rate = create(:zip_tax_rate, country: "NO", state: nil, zip_code: nil, combined_rate: 0.25, is_seller_responsible: false)
        create(:zip_tax_rate, country: "NO", state: nil, zip_code: nil, combined_rate: 0.00, is_seller_responsible: false, is_epublication_rate: true)

        expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                     tax_cents: 25,
                                                     zip_tax_rate: expected_tax_rate)

        actual_sales_tax = SalesTaxCalculator.new(product:,
                                                  price_cents: 100,
                                                  buyer_location: { country: "NO" }).calculate

        compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
      end

      it "uses the epublication VAT rate for ebpublication products in Norway" do
        product = create(:product, user: @seller, is_epublication: true)
        create(:zip_tax_rate, country: "NO", state: nil, zip_code: nil, combined_rate: 0.25, is_seller_responsible: false, is_epublication_rate: false)
        expected_tax_rate = create(:zip_tax_rate, country: "NO", state: nil, zip_code: nil, combined_rate: 0.00, is_seller_responsible: false, is_epublication_rate: true)

        expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                     tax_cents: 0,
                                                     zip_tax_rate: expected_tax_rate)

        actual_sales_tax = SalesTaxCalculator.new(product:,
                                                  price_cents: 100,
                                                  buyer_location: { country: "NO" }).calculate

        compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
      end
    end

    describe "Iceland VAT" do
      let!(:standard_tax_rate) { create(:zip_tax_rate, country: "IS", state: nil, zip_code: nil, combined_rate: 0.24, is_seller_responsible: false) }
      let!(:epublication_tax_rate) { create(:zip_tax_rate, country: "IS", state: nil, zip_code: nil, combined_rate: 0.11, is_seller_responsible: false, is_epublication_rate: true) }

      context "when collect_tax_is feature flag is off" do
        it "does not assess VAT in Iceland" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "IS" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "does not assess VAT for epublication products in Iceland" do
          product = create(:product, user: @seller, is_epublication: true)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "IS" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_is feature flag is on" do
        before do
          Feature.activate(:collect_tax_is)
        end

        it "assesses VAT in Iceland" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 24,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "IS" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "uses the epublication VAT rate for epublication products in Iceland" do
          product = create(:product, user: @seller, is_epublication: true)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 11,
                                                       zip_tax_rate: epublication_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "IS" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "Japan CT" do
      let!(:standard_tax_rate) { create(:zip_tax_rate, country: "JP", state: nil, zip_code: nil, combined_rate: 0.10, is_seller_responsible: false) }

      context "when collect_tax_jp feature flag is off" do
        it "does not assess CT in Japan" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "JP" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_jp feature flag is on" do
        before do
          Feature.activate(:collect_tax_jp)
        end

        it "assesses CT in Japan" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 10,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "JP" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "New Zealand GST" do
      let!(:standard_tax_rate) { create(:zip_tax_rate, country: "NZ", state: nil, zip_code: nil, combined_rate: 0.15, is_seller_responsible: false) }

      context "when collect_tax_nz feature flag is off" do
        it "does not assess GST in New Zealand" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "NZ" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_nz feature flag is on" do
        before do
          Feature.activate(:collect_tax_nz)
        end

        it "assesses GST in New Zealand" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 15,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "NZ" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "South Africa VAT" do
      let!(:standard_tax_rate) { create(:zip_tax_rate, country: "ZA", state: nil, zip_code: nil, combined_rate: 0.15, is_seller_responsible: false) }

      context "when collect_tax_za feature flag is off" do
        it "does not assess VAT in South Africa" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "ZA" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_za feature flag is on" do
        before do
          Feature.activate(:collect_tax_za)
        end

        it "assesses VAT in South Africa" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 15,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "ZA" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "Switzerland VAT" do
      let!(:standard_tax_rate) { create(:zip_tax_rate, country: "CH", state: nil, zip_code: nil, combined_rate: 0.081, is_seller_responsible: false) }
      let!(:epublication_tax_rate) { create(:zip_tax_rate, country: "CH", state: nil, zip_code: nil, combined_rate: 0.026, is_seller_responsible: false, is_epublication_rate: true) }

      context "when collect_tax_ch feature flag is off" do
        it "does not assess VAT in Switzerland" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "CH" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_ch feature flag is on" do
        before do
          Feature.activate(:collect_tax_ch)
        end

        it "assesses standard VAT rate in Switzerland for regular products" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 8.1,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "CH" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "assesses reduced VAT rate in Switzerland for epublications" do
          product = create(:product, user: @seller, is_epublication: true)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 2.6,
                                                       zip_tax_rate: epublication_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "CH" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "United Arab Emirates VAT" do
      let!(:standard_tax_rate) { create(:zip_tax_rate, country: "AE", state: nil, zip_code: nil, combined_rate: 0.05, is_seller_responsible: false) }

      context "when collect_tax_ae feature flag is off" do
        it "does not assess VAT in United Arab Emirates" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "AE" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_ae feature flag is on" do
        before do
          Feature.activate(:collect_tax_ae)
        end

        it "assesses VAT in United Arab Emirates" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 5,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "AE" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "India GST" do
      let!(:standard_tax_rate) { create(:zip_tax_rate, country: "IN", state: nil, zip_code: nil, combined_rate: 0.18, is_seller_responsible: false) }

      context "when collect_tax_in feature flag is off" do
        it "does not assess GST in India" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "IN" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_in feature flag is on" do
        before do
          Feature.activate(:collect_tax_in)
        end

        it "assesses GST in India" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 18,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "IN" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "Bahrain VAT" do
      let!(:standard_tax_rate) { create(:zip_tax_rate, country: "BH", state: nil, zip_code: nil, combined_rate: 0.10, is_seller_responsible: false) }

      context "when collect_tax_bh feature flag is off" do
        it "does not assess VAT in Bahrain" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "BH" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_bh feature flag is on" do
        before do
          Feature.activate(:collect_tax_bh)
        end

        it "assesses VAT in Bahrain" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 10,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "BH" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "does not assess VAT for physical products" do
          product = create(:physical_product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "BH" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "Belarus VAT" do
      let!(:standard_tax_rate) { create(:zip_tax_rate, country: "BY", state: nil, zip_code: nil, combined_rate: 0.20, is_seller_responsible: false) }

      context "when collect_tax_by feature flag is off" do
        it "does not assess VAT in Belarus" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "BY" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_by feature flag is on" do
        before do
          Feature.activate(:collect_tax_by)
        end

        it "assesses VAT in Belarus" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 20,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "BY" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "does not assess VAT for physical products" do
          product = create(:physical_product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "BY" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "Chile VAT" do
      let!(:standard_tax_rate) { create(:zip_tax_rate, country: "CL", state: nil, zip_code: nil, combined_rate: 0.19, is_seller_responsible: false) }

      context "when collect_tax_cl feature flag is off" do
        it "does not assess VAT in Chile" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "CL" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_cl feature flag is on" do
        before do
          Feature.activate(:collect_tax_cl)
        end

        it "assesses VAT in Chile" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 19,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "CL" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "does not assess VAT for physical products" do
          product = create(:physical_product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "CL" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "Colombia VAT" do
      let!(:standard_tax_rate) { create(:zip_tax_rate, country: "CO", state: nil, zip_code: nil, combined_rate: 0.19, is_seller_responsible: false) }

      context "when collect_tax_co feature flag is off" do
        it "does not assess VAT in Colombia" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "CO" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_co feature flag is on" do
        before do
          Feature.activate(:collect_tax_co)
        end

        it "assesses VAT in Colombia" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 19,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "CO" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "does not assess VAT for physical products" do
          product = create(:physical_product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "CO" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "Costa Rica VAT" do
      let!(:standard_tax_rate) { create(:zip_tax_rate, country: "CR", state: nil, zip_code: nil, combined_rate: 0.13, is_seller_responsible: false) }

      context "when collect_tax_cr feature flag is off" do
        it "does not assess VAT in Costa Rica" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "CR" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_cr feature flag is on" do
        before do
          Feature.activate(:collect_tax_cr)
        end

        it "assesses VAT in Costa Rica" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 13,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "CR" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "does not assess VAT for physical products" do
          product = create(:physical_product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "CR" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "Ecuador VAT" do
      let!(:standard_tax_rate) { create(:zip_tax_rate, country: "EC", state: nil, zip_code: nil, combined_rate: 0.12, is_seller_responsible: false) }

      context "when collect_tax_ec feature flag is off" do
        it "does not assess VAT in Ecuador" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "EC" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_ec feature flag is on" do
        before do
          Feature.activate(:collect_tax_ec)
        end

        it "assesses VAT in Ecuador" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 12,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "EC" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "does not assess VAT for physical products" do
          product = create(:physical_product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "EC" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "Egypt VAT" do
      let!(:standard_tax_rate) { create(:zip_tax_rate, country: "EG", state: nil, zip_code: nil, combined_rate: 0.14, is_seller_responsible: false) }

      context "when collect_tax_eg feature flag is off" do
        it "does not assess VAT in Egypt" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "EG" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_eg feature flag is on" do
        before do
          Feature.activate(:collect_tax_eg)
        end

        it "assesses VAT in Egypt" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 14,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "EG" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "does not assess VAT for physical products" do
          product = create(:physical_product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "EG" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "Georgia VAT" do
      let!(:standard_tax_rate) { create(:zip_tax_rate, country: "GE", state: nil, zip_code: nil, combined_rate: 0.18, is_seller_responsible: false) }

      context "when collect_tax_ge feature flag is off" do
        it "does not assess VAT in Georgia" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "GE" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_ge feature flag is on" do
        before do
          Feature.activate(:collect_tax_ge)
        end

        it "assesses VAT in Georgia" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 18,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "GE" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "does not assess VAT for physical products" do
          product = create(:physical_product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "GE" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "Kazakhstan VAT" do
      let!(:standard_tax_rate) { create(:zip_tax_rate, country: "KZ", state: nil, zip_code: nil, combined_rate: 0.12, is_seller_responsible: false) }

      context "when collect_tax_kz feature flag is off" do
        it "does not assess VAT in Kazakhstan" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "KZ" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_kz feature flag is on" do
        before do
          Feature.activate(:collect_tax_kz)
        end

        it "assesses VAT in Kazakhstan" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 12,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "KZ" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "does not assess VAT for physical products" do
          product = create(:physical_product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "KZ" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "Kenya VAT" do
      let!(:standard_tax_rate) { create(:zip_tax_rate, country: "KE", state: nil, zip_code: nil, combined_rate: 0.16, is_seller_responsible: false) }

      context "when collect_tax_ke feature flag is off" do
        it "does not assess VAT in Kenya" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "KE" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_ke feature flag is on" do
        before do
          Feature.activate(:collect_tax_ke)
        end

        it "assesses VAT in Kenya" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 16,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "KE" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "does not assess VAT for physical products" do
          product = create(:physical_product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "KE" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "Malaysia Service Tax" do
      let!(:standard_tax_rate) { create(:zip_tax_rate, country: "MY", state: nil, zip_code: nil, combined_rate: 0.06, is_seller_responsible: false) }

      context "when collect_tax_my feature flag is off" do
        it "does not assess Service Tax in Malaysia" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "MY" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_my feature flag is on" do
        before do
          Feature.activate(:collect_tax_my)
        end

        it "assesses Service Tax in Malaysia" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 6,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "MY" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "does not assess Service Tax for physical products" do
          product = create(:physical_product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "MY" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "Mexico VAT" do
      let!(:standard_tax_rate) { create(:zip_tax_rate, country: "MX", state: nil, zip_code: nil, combined_rate: 0.16, is_seller_responsible: false) }
      let!(:epublication_tax_rate) { create(:zip_tax_rate, country: "MX", state: nil, zip_code: nil, combined_rate: 0.00, is_seller_responsible: false, is_epublication_rate: true) }

      context "when collect_tax_mx feature flag is off" do
        it "does not assess VAT in Mexico" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "MX" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_mx feature flag is on" do
        before do
          Feature.activate(:collect_tax_mx)
        end

        it "assesses VAT in Mexico" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 16,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "MX" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "applies zero rate for e-publications" do
          product = create(:product, user: @seller, is_epublication: true)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 0,
                                                       zip_tax_rate: epublication_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "MX" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "does not assess VAT for physical products" do
          product = create(:physical_product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "MX" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "Moldova VAT" do
      let(:standard_tax_rate) { create(:zip_tax_rate, country: "MD", state: nil, zip_code: nil, combined_rate: 0.20, is_seller_responsible: false) }

      context "when collect_tax_md feature flag is off" do
        it "does not assess VAT" do
          product = create(:product, user: @seller)
          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "MD" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_md feature flag is on" do
        before do
          Feature.activate(:collect_tax_md)
        end

        it "assesses VAT in Moldova" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 20,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "MD" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "does not assess VAT for physical products" do
          product = create(:physical_product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "MD" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "Morocco VAT" do
      let(:standard_tax_rate) { create(:zip_tax_rate, country: "MA", state: nil, zip_code: nil, combined_rate: 0.20, is_seller_responsible: false) }

      context "when collect_tax_ma feature flag is off" do
        it "does not assess VAT" do
          product = create(:product, user: @seller)
          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "MA" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_ma feature flag is on" do
        before do
          Feature.activate(:collect_tax_ma)
        end

        it "assesses VAT in Morocco" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 20,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "MA" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "does not assess VAT for physical products" do
          product = create(:physical_product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "MA" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "Nigeria VAT" do
      let(:standard_tax_rate) { create(:zip_tax_rate, country: "NG", state: nil, zip_code: nil, combined_rate: 0.075, is_seller_responsible: false) }

      context "when collect_tax_ng feature flag is off" do
        it "does not assess VAT" do
          product = create(:product, user: @seller)
          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "NG" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_ng feature flag is on" do
        before do
          Feature.activate(:collect_tax_ng)
        end

        it "assesses VAT in Nigeria" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 7.5,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "NG" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "does not assess VAT for physical products" do
          product = create(:physical_product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "NG" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "Oman VAT" do
      let(:standard_tax_rate) { create(:zip_tax_rate, country: "OM", state: nil, zip_code: nil, combined_rate: 0.05, is_seller_responsible: false) }

      context "when collect_tax_om feature flag is off" do
        it "does not assess VAT" do
          product = create(:product, user: @seller)
          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "OM" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_om feature flag is on" do
        before do
          Feature.activate(:collect_tax_om)
        end

        it "assesses VAT in Oman" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 5,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "OM" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "does not assess VAT for physical products" do
          product = create(:physical_product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "OM" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "Russia VAT" do
      let(:standard_tax_rate) { create(:zip_tax_rate, country: "RU", state: nil, zip_code: nil, combined_rate: 0.20, is_seller_responsible: false) }

      context "when collect_tax_ru feature flag is off" do
        it "does not assess VAT" do
          product = create(:product, user: @seller)
          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "RU" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_ru feature flag is on" do
        before do
          Feature.activate(:collect_tax_ru)
        end

        it "assesses VAT in Russia" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 20,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "RU" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "does not assess VAT for physical products" do
          product = create(:physical_product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "RU" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "Saudi Arabia VAT" do
      let(:standard_tax_rate) { create(:zip_tax_rate, country: "SA", state: nil, zip_code: nil, combined_rate: 0.15, is_seller_responsible: false) }

      context "when collect_tax_sa feature flag is off" do
        it "does not assess VAT" do
          product = create(:product, user: @seller)
          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "SA" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_sa feature flag is on" do
        before do
          Feature.activate(:collect_tax_sa)
        end

        it "assesses VAT in Saudi Arabia" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 15,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "SA" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "does not assess VAT for physical products" do
          product = create(:physical_product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "SA" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "Serbia VAT" do
      let(:standard_tax_rate) { create(:zip_tax_rate, country: "RS", state: nil, zip_code: nil, combined_rate: 0.20, is_seller_responsible: false) }

      context "when collect_tax_rs feature flag is off" do
        it "does not assess VAT" do
          product = create(:product, user: @seller)
          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "RS" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_rs feature flag is on" do
        before do
          Feature.activate(:collect_tax_rs)
        end

        it "assesses VAT in Serbia" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 20,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "RS" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "does not assess VAT for physical products" do
          product = create(:physical_product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "RS" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "South Korea VAT" do
      let(:standard_tax_rate) { create(:zip_tax_rate, country: "KR", state: nil, zip_code: nil, combined_rate: 0.10, is_seller_responsible: false) }

      context "when collect_tax_kr feature flag is off" do
        it "does not assess VAT" do
          product = create(:product, user: @seller)
          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "KR" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_kr feature flag is on" do
        before do
          Feature.activate(:collect_tax_kr)
        end

        it "assesses VAT in South Korea" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 10,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "KR" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "does not assess VAT for physical products" do
          product = create(:physical_product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "KR" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "Tanzania VAT" do
      let(:standard_tax_rate) { create(:zip_tax_rate, country: "TZ", state: nil, zip_code: nil, combined_rate: 0.18, is_seller_responsible: false) }

      context "when collect_tax_tz feature flag is off" do
        it "does not assess VAT" do
          product = create(:product, user: @seller)
          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "TZ" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_tz feature flag is on" do
        before do
          Feature.activate(:collect_tax_tz)
        end

        it "assesses VAT in Tanzania" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 18,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "TZ" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "does not assess VAT for physical products" do
          product = create(:physical_product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "TZ" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "Thailand VAT" do
      let(:standard_tax_rate) { create(:zip_tax_rate, country: "TH", state: nil, zip_code: nil, combined_rate: 0.07, is_seller_responsible: false) }

      context "when collect_tax_th feature flag is off" do
        it "does not assess VAT" do
          product = create(:product, user: @seller)
          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "TH" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_th feature flag is on" do
        before do
          Feature.activate(:collect_tax_th)
        end

        it "assesses VAT in Thailand" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 7,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "TH" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "does not assess VAT for physical products" do
          product = create(:physical_product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "TH" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "Turkey VAT" do
      let(:standard_tax_rate) { create(:zip_tax_rate, country: "TR", state: nil, zip_code: nil, combined_rate: 0.20, is_seller_responsible: false) }

      context "when collect_tax_tr feature flag is off" do
        it "does not assess VAT" do
          product = create(:product, user: @seller)
          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "TR" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_tr feature flag is on" do
        before do
          Feature.activate(:collect_tax_tr)
        end

        it "assesses VAT in Turkey" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 20,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "TR" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "does not assess VAT for physical products" do
          product = create(:physical_product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "TR" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "Ukraine VAT" do
      let(:standard_tax_rate) { create(:zip_tax_rate, country: "UA", state: nil, zip_code: nil, combined_rate: 0.20, is_seller_responsible: false) }

      context "when collect_tax_ua feature flag is off" do
        it "does not assess VAT" do
          product = create(:product, user: @seller)
          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "UA" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_ua feature flag is on" do
        before do
          Feature.activate(:collect_tax_ua)
        end

        it "assesses VAT in Ukraine" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 20,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "UA" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "does not assess VAT for physical products" do
          product = create(:physical_product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "UA" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "Uzbekistan VAT" do
      let(:standard_tax_rate) { create(:zip_tax_rate, country: "UZ", state: nil, zip_code: nil, combined_rate: 0.15, is_seller_responsible: false) }

      context "when collect_tax_uz feature flag is off" do
        it "does not assess VAT" do
          product = create(:product, user: @seller)
          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "UZ" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_uz feature flag is on" do
        before do
          Feature.activate(:collect_tax_uz)
        end

        it "assesses VAT in Uzbekistan" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 15,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "UZ" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "does not assess VAT for physical products" do
          product = create(:physical_product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "UZ" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "Vietnam VAT" do
      let(:standard_tax_rate) { create(:zip_tax_rate, country: "VN", state: nil, zip_code: nil, combined_rate: 0.10, is_seller_responsible: false) }

      context "when collect_tax_vn feature flag is off" do
        it "does not assess VAT" do
          product = create(:product, user: @seller)
          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "VN" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      context "when collect_tax_vn feature flag is on" do
        before do
          Feature.activate(:collect_tax_vn)
        end

        it "assesses VAT in Vietnam" do
          product = create(:product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 10,
                                                       zip_tax_rate: standard_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "VN" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        it "does not assess VAT for physical products" do
          product = create(:physical_product, user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "VN" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    describe "EU VAT" do
      before do
        @seller.collect_eu_vat = true
        @seller.is_eu_vat_exclusive = false
        @seller.save!

        create(:zip_tax_rate, country: "ES", state: nil, zip_code: nil, combined_rate: 0.10, is_seller_responsible: true)
      end

      it "does not assess VAT in VAT-exempt EU territories" do
        expect_zero_tax_for(country: "ES", ip_address: "193.145.138.32") # Canary Islands
        expect_zero_tax_for(country: "ES", ip_address: "193.145.147.158") # Canary Islands
      end

      it "assesses VAT in EU country" do
        product = create(:product, user: @seller)
        expected_tax_rate = create(:zip_tax_rate, country: "IT", state: nil, zip_code: nil, combined_rate: 0.22, is_seller_responsible: false)

        expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                     tax_cents: 22,
                                                     zip_tax_rate: expected_tax_rate)

        actual_sales_tax = SalesTaxCalculator.new(product:,
                                                  price_cents: 100,
                                                  buyer_location: { country: "IT" }).calculate

        compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
      end

      it "does not assess VAT in EU country if seller has a Brazilian Stripe Connect account" do
        product = create(:product, user: @seller)
        @seller.update!(check_merchant_account_is_linked: true)
        create(:merchant_account_stripe_connect, user: @seller, country: "BR", charge_processor_merchant_id: "acct_1QADdCGy0w4tFIUe")
        create(:zip_tax_rate, country: "IT", state: nil, zip_code: nil, combined_rate: 0.22, is_seller_responsible: false)

        expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                     tax_cents: 0,
                                                     zip_tax_rate: nil)

        actual_sales_tax = SalesTaxCalculator.new(product:,
                                                  price_cents: 100,
                                                  buyer_location: { country: "IT" }).calculate

        compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
      end

      it "assesses VAT for physical products in EU country" do
        product = create(:physical_product, user: @seller)
        expected_tax_rate = create(:zip_tax_rate, country: "IT", state: nil, zip_code: nil, combined_rate: 0.22, is_seller_responsible: false)

        expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                     tax_cents: 22,
                                                     zip_tax_rate: expected_tax_rate)

        actual_sales_tax = SalesTaxCalculator.new(product:,
                                                  price_cents: 100,
                                                  buyer_location: { country: "IT" }).calculate

        compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
      end

      it "uses the standard VAT rate for non e-publication products in the EU" do
        product = create(:product, user: @seller)
        create(:zip_tax_rate, country: "AT", zip_code: nil, state: nil, combined_rate: 0.10, is_seller_responsible: false, is_epublication_rate: true)
        expected_tax_rate = create(:zip_tax_rate, country: "AT", zip_code: nil, state: nil, combined_rate: 0.20, is_seller_responsible: false, is_epublication_rate: false)

        expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                     tax_cents: 20,
                                                     zip_tax_rate: expected_tax_rate)

        actual_sales_tax = SalesTaxCalculator.new(product:,
                                                  price_cents: 100,
                                                  buyer_location: { country: "AT" }).calculate

        compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
      end

      it "uses the epublication VAT rate for ebpublication products in the EU" do
        product = create(:product, user: @seller, is_epublication: true)
        create(:zip_tax_rate, country: "AT", zip_code: nil, state: nil, combined_rate: 0.20, is_seller_responsible: false, is_epublication_rate: false)
        expected_tax_rate = create(:zip_tax_rate, country: "AT", zip_code: nil, state: nil, combined_rate: 0.10, is_seller_responsible: false, is_epublication_rate: true)

        expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                     tax_cents: 10,
                                                     zip_tax_rate: expected_tax_rate)

        actual_sales_tax = SalesTaxCalculator.new(product:,
                                                  price_cents: 100,
                                                  buyer_location: { country: "AT" }).calculate

        compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
      end

      it "uses the epublication VAT rate for ebpublication products in the EU even when the VAT rate is zero" do
        product = create(:product, user: @seller, is_epublication: true)
        create(:zip_tax_rate, country: "GB", zip_code: nil, state: nil, combined_rate: 0.20, is_seller_responsible: false, is_epublication_rate: false)
        expected_tax_rate = create(:zip_tax_rate, country: "GB", zip_code: nil, state: nil, combined_rate: 0.00, is_seller_responsible: false, is_epublication_rate: true)

        expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                     tax_cents: 0,
                                                     zip_tax_rate: expected_tax_rate)

        actual_sales_tax = SalesTaxCalculator.new(product:,
                                                  price_cents: 100,
                                                  buyer_location: { country: "GB" }).calculate

        compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
      end

      def expect_zero_tax_for(buyer_location)
        actual_sales_tax = SalesTaxCalculator.new(product: create(:product, user: @seller),
                                                  price_cents: 100,
                                                  buyer_location:).calculate

        compare_calculations(expected: SalesTaxCalculation.zero_tax(100), actual: actual_sales_tax)
      end
    end

    describe "EU VAT controls for merchant migrated account" do
      before do
        Feature.activate_user(:merchant_migration, @seller)
      end

      after do
        Feature.deactivate_user(:merchant_migration, @seller)
      end

      it "ignores seller taxable regions and overrides inclusive taxation when applicable (non-US)" do
        @seller.collect_eu_vat = true
        @seller.is_eu_vat_exclusive = true
        @seller.save!

        expected_tax_rate = create(:zip_tax_rate, country: "ES", zip_code: nil, state: nil, combined_rate: 0.21, is_seller_responsible: false)

        expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                     tax_cents: 21,
                                                     zip_tax_rate: expected_tax_rate)

        actual_sales_tax = SalesTaxCalculator.new(product: create(:product, user: @seller),
                                                  price_cents: 100,
                                                  buyer_location: { country: "ES" },).calculate

        compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
      end

      it "ignores seller taxable regions and ignores VAT when applicable (non-US)" do
        @seller.collect_eu_vat = false
        @seller.save!

        expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                     tax_cents: 0,
                                                     zip_tax_rate: nil)

        actual_sales_tax = SalesTaxCalculator.new(product: create(:product, user: @seller),
                                                  price_cents: 100,
                                                  buyer_location: { country: "ES" },).calculate

        compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
      end
    end
  end

  def compare_calculations(expected:, actual:)
    expect(expected.is_a?(SalesTaxCalculation)).to be(true)
    expect(actual.is_a?(SalesTaxCalculation)).to be(true)

    expect(actual.price_cents).to eq(expected.price_cents)
    expect(actual.tax_cents).to eq(expected.tax_cents)
    expect(actual.zip_tax_rate).to eq(expected.zip_tax_rate)
    expect(actual.used_taxjar).to eq(expected.used_taxjar)
    expect(actual.taxjar_info).to eq(expected.taxjar_info)
  end
end
