# frozen_string_literal: true

require "test_helper"

# Contexts are real ActiveSupport::TestCase subclasses, so they inherit Rails'
# transactional setup and the shared model builders. Child contexts undefine
# inherited test methods; each example therefore runs exactly once in its own
# context, while setup/teardown blocks still chain through the parent context.
module NestedMinitestContext
  def describe(description, *additional, &block)
    child = Class.new(self)
    context_name = [@context_name, description, *additional].compact.join(" / ")
    child.instance_variable_set(:@context_name, context_name)
    # Anonymous classes report a nil name, which makes a failure in one of the 34
    # near-identical country contexts unattributable (several descriptions repeat
    # verbatim across contexts) and leaves no `-n` selector to re-run it.
    child.define_singleton_method(:name) { context_name }
    child.public_instance_methods.grep(/\Atest_/).each { |method_name| child.send(:undef_method, method_name) }
    (@nested_contexts ||= []) << child
    child.class_eval(&block)
    child
  end
  alias context describe

  def test(description, &block)
    @test_counter = (@test_counter || 0) + 1
    method_name = "test_%04d_%s" % [@test_counter, description]
    define_method(method_name, &block)
    (@nested_contexts || []).each do |child|
      # Only hide a test the child INHERITED. @test_counter restarts per class, so a
      # parent test declared after a nested context can generate the same
      # test_<ordinal>_<description> name as one the child defined itself; undefining
      # by name alone would silently delete the child's test and it would run zero times.
      next unless child.public_method_defined?(method_name)
      next if child.instance_methods(false).include?(method_name.to_sym)

      child.send(:undef_method, method_name)
    end
    method_name
  end

  def setup(&block)
    @setup_blocks ||= []
    @setup_blocks << block
    blocks = @setup_blocks
    define_method(:setup) do
      super()
      blocks.each { |setup_block| instance_eval(&setup_block) }
    end
  end

  def teardown(&block)
    @teardown_blocks ||= []
    @teardown_blocks << block
    blocks = @teardown_blocks
    define_method(:teardown) do
      blocks.reverse_each { |teardown_block| instance_eval(&teardown_block) }
      super()
    end
  end

  def shared_examples(name, &block)
    @shared_examples ||= {}
    @shared_examples[name] = block
  end

  def include_examples(name, *args, &block)
    class_exec(*args, &(block || @shared_examples.fetch(name)))
  end
end

# Ported from spec/business/sales_tax/sales_tax_calculator_spec.rb (#5801).
class SalesTaxCalculatorTest < ActiveSupport::TestCase
  extend NestedMinitestContext

  describe SalesTaxCalculator do
    describe "input validation" do
      test "only accepts a hash for buyer location info" do
        error = assert_raises(SalesTaxCalculatorValidationError) do
          SalesTaxCalculator.new(product: create_product,
                                 price_cents: 100,
                                 buyer_location: 123_456).calculate
        end
        assert_equal "Buyer Location should be a Hash", error.message
      end

      test "only accepts an integer for base price in cents" do
        error = assert_raises(SalesTaxCalculatorValidationError) do
          SalesTaxCalculator.new(product: create_product,
                                 price_cents: 100.0,
                                 buyer_location: { postal_code: "12345", country: "US" }).calculate
        end
        assert_equal "Price (cents) should be an Integer", error.message
      end

      test "requires product to be an instance of the class" do
        error = assert_raises(SalesTaxCalculatorValidationError) do
          SalesTaxCalculator.new(product: [],
                                 price_cents: 100,
                                 buyer_location: { postal_code: "12345", country: "US" },).calculate
        end
        assert_equal "Product should be a Link instance", error.message
      end
    end

    describe "#calculate" do
      setup do
        @seller = create_user
      end

      test "returns zero tax if the base price is 0" do
        sales_tax = SalesTaxCalculator.new(product: create_product(user: @seller),
                                           price_cents: 0,
                                           buyer_location: { postal_code: "12345", country: "US" }).calculate

        compare_calculations(expected: SalesTaxCalculation.zero_tax(0), actual: sales_tax)
      end

      # The only rate on file is seller-responsible, which the lookup scope skips, so no rate is
      # found at all. Nothing here exercises the import logic — see the import context below.
      test "returns zero tax when the only matching rate is seller-responsible" do
        create_zip_tax_rate(country: "DE", zip_code: nil, state: nil)

        sales_tax = SalesTaxCalculator.new(product: create_physical_product(user: @seller),
                                           price_cents: 100,
                                           buyer_location: { country: "DE" }).calculate

        compare_calculations(expected: SalesTaxCalculation.zero_tax(100), actual: sales_tax)
      end

      context "physical products shipped to the EU" do
        # No IOSS registration, so anything collected here could not be remitted and the buyer paid
        # the same VAT again to customs on delivery.
        test "returns zero tax for a physical product shipped to an EU member state" do
          create_zip_tax_rate(country: "LT", zip_code: nil, state: nil, combined_rate: 0.21, is_seller_responsible: false)

          sales_tax = SalesTaxCalculator.new(product: create_physical_product(user: @seller),
                                             price_cents: 12_500,
                                             shipping_cents: 4_000,
                                             buyer_location: { country: "LT" }).calculate

          compare_calculations(expected: SalesTaxCalculation.zero_tax(12_500), actual: sales_tax)
        end

        # Origin does not enter into it: we have no IOSS number to remit under or to present at the
        # border wherever the parcel starts. These four cover the origins the previous revision of
        # this fix branched on, so re-introducing an origin test reddens them.
        test "returns zero tax when the seller ships from inside the EU" do
          create_zip_tax_rate(country: "LT", zip_code: nil, state: nil, combined_rate: 0.21, is_seller_responsible: false)
          create_user_compliance_info(user: @seller, country: "Germany")

          sales_tax = SalesTaxCalculator.new(product: create_physical_product(user: @seller),
                                             price_cents: 100,
                                             buyer_location: { country: "LT" }).calculate

          compare_calculations(expected: SalesTaxCalculation.zero_tax(100), actual: sales_tax)
        end

        test "returns zero tax on a domestic EU shipment" do
          create_zip_tax_rate(country: "DE", zip_code: nil, state: nil, combined_rate: 0.19, is_seller_responsible: false)
          create_user_compliance_info(user: @seller, country: "Germany")

          sales_tax = SalesTaxCalculator.new(product: create_physical_product(user: @seller),
                                             price_cents: 100,
                                             buyer_location: { country: "DE" }).calculate

          compare_calculations(expected: SalesTaxCalculation.zero_tax(100), actual: sales_tax)
        end

        test "returns zero tax when the seller ships from the UK into the EU" do
          create_zip_tax_rate(country: "LT", zip_code: nil, state: nil, combined_rate: 0.21, is_seller_responsible: false)
          create_user_compliance_info(user: @seller, country: "United Kingdom")

          sales_tax = SalesTaxCalculator.new(product: create_physical_product(user: @seller),
                                             price_cents: 100,
                                             buyer_location: { country: "LT" }).calculate

          compare_calculations(expected: SalesTaxCalculation.zero_tax(100), actual: sales_tax)
        end

        test "returns zero tax when the seller has no compliance country on file" do
          create_zip_tax_rate(country: "LT", zip_code: nil, state: nil, combined_rate: 0.21, is_seller_responsible: false)
          @seller.alive_user_compliance_info&.mark_deleted!

          sales_tax = SalesTaxCalculator.new(product: create_physical_product(user: @seller),
                                             price_cents: 100,
                                             buyer_location: { country: "LT" }).calculate

          compare_calculations(expected: SalesTaxCalculation.zero_tax(100), actual: sales_tax)
        end

        # The UK has its own registration and the marketplace collects under £135, so the border does
        # not charge again — this is the one physical destination that still assesses.
        test "still assesses VAT on a physical product shipped to the UK" do
          expected_tax_rate = create_zip_tax_rate(country: "GB", zip_code: nil, state: nil, combined_rate: 0.20, is_seller_responsible: false)

          sales_tax = SalesTaxCalculator.new(product: create_physical_product(user: @seller),
                                             price_cents: 100,
                                             buyer_location: { country: "GB" }).calculate

          compare_calculations(expected: SalesTaxCalculation.new(price_cents: 100, tax_cents: 20, zip_tax_rate: expected_tax_rate),
                               actual: sales_tax)
        end

        test "still assesses VAT on a digital product shipped to the same country" do
          expected_tax_rate = create_zip_tax_rate(country: "LT", zip_code: nil, state: nil, combined_rate: 0.21, is_seller_responsible: false)

          sales_tax = SalesTaxCalculator.new(product: create_product(user: @seller),
                                             price_cents: 100,
                                             buyer_location: { country: "LT" }).calculate

          compare_calculations(expected: SalesTaxCalculation.new(price_cents: 100, tax_cents: 21, zip_tax_rate: expected_tax_rate),
                               actual: sales_tax)
        end

        # These hold their own goods-capable registrations, and their low-value-import rules require
        # the marketplace to collect at checkout instead of the border.
        test "still assesses VAT on a physical product shipped to the UK" do
          expected_tax_rate = create_zip_tax_rate(country: "GB", zip_code: nil, state: nil, combined_rate: 0.20, is_seller_responsible: false)

          sales_tax = SalesTaxCalculator.new(product: create_physical_product(user: @seller),
                                             price_cents: 100,
                                             buyer_location: { country: "GB" }).calculate

          compare_calculations(expected: SalesTaxCalculation.new(price_cents: 100, tax_cents: 20, zip_tax_rate: expected_tax_rate),
                               actual: sales_tax)
        end

        test "still assesses VAT on a physical product shipped to Norway" do
          expected_tax_rate = create_zip_tax_rate(country: "NO", zip_code: nil, state: nil, combined_rate: 0.25, is_seller_responsible: false)

          sales_tax = SalesTaxCalculator.new(product: create_physical_product(user: @seller),
                                             price_cents: 100,
                                             buyer_location: { country: "NO" }).calculate

          compare_calculations(expected: SalesTaxCalculation.new(price_cents: 100, tax_cents: 25, zip_tax_rate: expected_tax_rate),
                               actual: sales_tax)
        end

        # Guards the seller-rate escape against legacy console-created rows; nothing in the app
        # writes seller-owned rates today.
        test "still assesses a seller-supplied EU rate on a physical product" do
          seller_rate = create_zip_tax_rate(country: "LT", zip_code: nil, state: nil, combined_rate: 0.21,
                                            is_seller_responsible: false, user_id: @seller.id)

          sales_tax = SalesTaxCalculator.new(product: create_physical_product(user: @seller),
                                             price_cents: 100,
                                             buyer_location: { country: "LT" }).calculate

          compare_calculations(expected: SalesTaxCalculation.new(price_cents: 100, tax_cents: 21, zip_tax_rate: seller_rate),
                               actual: sales_tax)
        end

        test "still assesses US state tax on a physical product when TaxJar is unavailable" do
          expected_tax_rate = create_zip_tax_rate(country: "US", state: "NY", zip_code: nil, combined_rate: 0.08,
                                                  is_seller_responsible: false)
          TaxjarApi.any_instance.stubs(:calculate_tax_for_order).raises(Taxjar::Error::InternalServerError)

          sales_tax = SalesTaxCalculator.new(product: create_physical_product(user: @seller),
                                             price_cents: 100,
                                             buyer_location: { country: "US", postal_code: "10012" }).calculate

          compare_calculations(expected: SalesTaxCalculation.new(price_cents: 100, tax_cents: 8, zip_tax_rate: expected_tax_rate),
                               actual: sales_tax)
        end

        # A bundle's own Link is not is_physical, so before this the carve-out read every bundle as
        # digital and collected on parcels customs charges again.
        context "when the physical goods are sold inside a bundle" do
          def bundle_of(*products)
            create_product(user: @seller, is_bundle: true).tap do |bundle|
              products.each { create_bundle_product(bundle:, product: _1) }
              bundle.bundle_products.reload
            end
          end

          test "returns zero tax when every component ships" do
            create_zip_tax_rate(country: "LT", zip_code: nil, state: nil, combined_rate: 0.21, is_seller_responsible: false)
            bundle = bundle_of(create_physical_product(user: @seller), create_physical_product(user: @seller))

            sales_tax = SalesTaxCalculator.new(product: bundle,
                                               price_cents: 12_500,
                                               shipping_cents: 4_000,
                                               buyer_location: { country: "LT" }).calculate

            compare_calculations(expected: SalesTaxCalculation.zero_tax(12_500), actual: sales_tax)
          end

          test "still assesses VAT on a bundle that mixes physical and digital components" do
            expected_tax_rate = create_zip_tax_rate(country: "LT", zip_code: nil, state: nil, combined_rate: 0.21, is_seller_responsible: false)
            bundle = bundle_of(create_physical_product(user: @seller), create_product(user: @seller))

            sales_tax = SalesTaxCalculator.new(product: bundle,
                                               price_cents: 100,
                                               buyer_location: { country: "LT" }).calculate

            compare_calculations(expected: SalesTaxCalculation.new(price_cents: 100, tax_cents: 21, zip_tax_rate: expected_tax_rate),
                                 actual: sales_tax)
          end

          test "still assesses VAT on an all-digital bundle" do
            expected_tax_rate = create_zip_tax_rate(country: "LT", zip_code: nil, state: nil, combined_rate: 0.21, is_seller_responsible: false)
            bundle = bundle_of(create_product(user: @seller), create_product(user: @seller))

            sales_tax = SalesTaxCalculator.new(product: bundle,
                                               price_cents: 100,
                                               buyer_location: { country: "LT" }).calculate

            compare_calculations(expected: SalesTaxCalculation.new(price_cents: 100, tax_cents: 21, zip_tax_rate: expected_tax_rate),
                                 actual: sales_tax)
          end

          # Converting a physical product into a bundle leaves its own is_physical set, so the row says
          # "ships" while the thing being sold includes a digital component we still owe VAT on.
          test "still assesses VAT when a converted physical product carries a digital component" do
            expected_tax_rate = create_zip_tax_rate(country: "LT", zip_code: nil, state: nil, combined_rate: 0.21, is_seller_responsible: false)
            bundle = create_physical_product(user: @seller)
            bundle.is_bundle = true
            bundle.native_type = Link::NATIVE_TYPE_BUNDLE
            create_bundle_product(bundle:, product: create_product(user: @seller))
            bundle.save!

            sales_tax = SalesTaxCalculator.new(product: bundle.reload,
                                               price_cents: 100,
                                               buyer_location: { country: "LT" }).calculate

            compare_calculations(expected: SalesTaxCalculation.new(price_cents: 100, tax_cents: 21, zip_tax_rate: expected_tax_rate),
                                 actual: sales_tax)
          end

          # A removed component must not silently change what the remaining ones are taxed as.
          test "ignores deleted components when deciding whether the bundle ships" do
            create_zip_tax_rate(country: "LT", zip_code: nil, state: nil, combined_rate: 0.21, is_seller_responsible: false)
            bundle = bundle_of(create_physical_product(user: @seller), create_product(user: @seller))
            bundle.bundle_products.find { !_1.product.is_physical? }.mark_deleted!

            sales_tax = SalesTaxCalculator.new(product: bundle,
                                               price_cents: 100,
                                               buyer_location: { country: "LT" }).calculate

            compare_calculations(expected: SalesTaxCalculation.zero_tax(100), actual: sales_tax)
          end

          # Deleting the component PRODUCT does not cascade to the join row, so the bundle still sells
          # and still ships it — the tax lane has to read it the same way checkout does.
          test "counts a component whose product row is deleted" do
            create_zip_tax_rate(country: "LT", zip_code: nil, state: nil, combined_rate: 0.21, is_seller_responsible: false)
            physical = create_physical_product(user: @seller)
            bundle = bundle_of(physical, create_physical_product(user: @seller))
            physical.delete!

            sales_tax = SalesTaxCalculator.new(product: bundle,
                                               price_cents: 100,
                                               buyer_location: { country: "LT" }).calculate

            compare_calculations(expected: SalesTaxCalculation.zero_tax(100), actual: sales_tax)
          end

          # No live components means no parcel to import; an empty bundle must not fall into the
          # carve-out just because nothing contradicts it.
          test "still assesses VAT on a bundle with no live components" do
            expected_tax_rate = create_zip_tax_rate(country: "LT", zip_code: nil, state: nil, combined_rate: 0.21, is_seller_responsible: false)
            bundle = create_product(user: @seller, is_bundle: true)

            sales_tax = SalesTaxCalculator.new(product: bundle,
                                               price_cents: 100,
                                               buyer_location: { country: "LT" }).calculate

            compare_calculations(expected: SalesTaxCalculation.new(price_cents: 100, tax_cents: 21, zip_tax_rate: expected_tax_rate),
                                 actual: sales_tax)
          end

          # Origin no longer enters the predicate — #6604 dropped the seller-country proxy per the
          # ruling to stop collecting physical EU VAT at all — so an EU-established seller's
          # all-physical bundle is carved out exactly like a non-EU seller's.
          test "returns zero tax on an all-physical bundle when the seller is established inside the EU" do
            create_zip_tax_rate(country: "LT", zip_code: nil, state: nil, combined_rate: 0.21, is_seller_responsible: false)
            create_user_compliance_info(user: @seller, country: "Germany")
            bundle = bundle_of(create_physical_product(user: @seller), create_physical_product(user: @seller))

            sales_tax = SalesTaxCalculator.new(product: bundle,
                                               price_cents: 100,
                                               buyer_location: { country: "LT" }).calculate

            compare_calculations(expected: SalesTaxCalculation.zero_tax(100), actual: sales_tax)
          end

          test "still assesses VAT on an all-physical bundle shipped to the UK" do
            expected_tax_rate = create_zip_tax_rate(country: "GB", zip_code: nil, state: nil, combined_rate: 0.20, is_seller_responsible: false)
            bundle = bundle_of(create_physical_product(user: @seller), create_physical_product(user: @seller))

            sales_tax = SalesTaxCalculator.new(product: bundle,
                                               price_cents: 100,
                                               buyer_location: { country: "GB" }).calculate

            compare_calculations(expected: SalesTaxCalculation.new(price_cents: 100, tax_cents: 20, zip_tax_rate: expected_tax_rate),
                                 actual: sales_tax)
          end
        end
      end

      test "ignores seller taxable regions and overrides inclusive taxation when applicable (non-US)" do
        expected_tax_rate = create_zip_tax_rate(country: "ES", zip_code: nil, state: nil, combined_rate: 0.21, is_seller_responsible: false)

        expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                     tax_cents: 21,
                                                     zip_tax_rate: expected_tax_rate)

        actual_sales_tax = SalesTaxCalculator.new(product: create_product(user: @seller),
                                                  price_cents: 100,
                                                  buyer_location: { country: "ES" },).calculate

        compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
      end

      test "returns whole-cent tax amounts when the rate produces a fractional cent (regression for buyer-currency quote total mismatch)" do
        # India GST 18% on a $9.99 product yields 179.82 fractional cents. Before rounding
        # here, the checkout quote endpoint rounded the summed total (=> 180 within 1179)
        # while charge-time persistence truncated via the integer column (=> 179 within
        # 1178), so the buyer-currency quote's locked canonical total never matched at
        # charge time for Gumroad-collected VAT/GST checkouts.
        expected_tax_rate = create_zip_tax_rate(country: "IN", zip_code: nil, state: nil, combined_rate: 0.18, is_seller_responsible: false)
        Feature.activate("collect_tax_in")

        actual_sales_tax = SalesTaxCalculator.new(product: create_product(user: @seller),
                                                  price_cents: 999,
                                                  buyer_location: { country: "IN" }).calculate

        assert_equal 180, actual_sales_tax.tax_cents
        assert_equal expected_tax_rate, actual_sales_tax.zip_tax_rate
      ensure
        Feature.deactivate("collect_tax_in")
      end

      describe "with TaxJar" do
        setup do
          # The cassettes were recorded under RSpec, which derived the path from the
          # describe/context/it chain. Rebuild that name from the Minitest method name.
          cassette_name = name.sub(/\Atest_\d+_/, "").gsub(/[^0-9A-Za-z_]/, "_")
          VCR.insert_cassette("SalesTaxCalculator/_calculate/with_TaxJar/#{cassette_name}")
        end

        teardown do
          VCR.eject_cassette
        end

        setup do
          @creator = create_user_with_compliance_info

          @product = create_physical_product(user: @creator, require_shipping: true, price_cents: 1000)
          @product.shipping_destinations << ShippingDestination.new(country_code: "US", one_item_rate_cents: 100, multiple_items_rate_cents: 200)
          @product.save!
        end

        test "calculates with TaxJar for a state where shipping is taxable" do
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

        test "does not call TaxJar and returns zero tax when customer zip code is invalid" do
          TaxjarApi.any_instance.expects(:calculate_tax_for_order).never

          calculation = SalesTaxCalculator.new(product: @product,
                                               price_cents: @product.price_cents,
                                               shipping_cents: @product.shipping_destinations.last.one_item_rate_cents,
                                               quantity: 1,
                                               buyer_location: { postal_code: "invalidzip", country: "US" }).calculate

          compare_calculations(expected: SalesTaxCalculation.zero_tax(@product.price_cents), actual: calculation)
        end

        test "does not call TaxJar and returns zero tax when creator doesn't have nexus in the state of the customer zip" do
          TaxjarApi.any_instance.expects(:calculate_tax_for_order).never

          calculation = SalesTaxCalculator.new(product: @product,
                                               price_cents: @product.price_cents,
                                               shipping_cents: @product.shipping_destinations.last.one_item_rate_cents,
                                               quantity: 1,
                                               buyer_location: { postal_code: "94107", country: "US" }).calculate

          compare_calculations(expected: SalesTaxCalculation.zero_tax(@product.price_cents), actual: calculation)
        end

        test "does not charge tax for purchases in situations where Gumroad is not responsible for tax" do
          actual_sales_tax = SalesTaxCalculator.new(product: create_product(user: @seller),
                                                    price_cents: 100,
                                                    buyer_location: { country: "US", postal_code: "94104" },
                                                    from_discover: true).calculate

          compare_calculations(expected: SalesTaxCalculation.zero_tax(100), actual: actual_sales_tax)
        end

        shared_examples "valid tax calculation for a US state" do |state, county, city, zip_code, combined_rate, state_rate, county_rate, city_rate|
          test "performs a valid tax calculation for #{state} when the sale is recommended" do
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
              product: create_product(user: @seller),
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
          test "performs a valid tax calculation for #{state} when the sale is not recommended" do
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
              product: create_product(user: @seller),
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

        test "performs a valid tax calculation for Ontario Canada purchases" do
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

          actual_sales_tax = SalesTaxCalculator.new(product: create_product(user: @seller),
                                                    price_cents: 100,
                                                    buyer_location: { country: "CA", state: "ON" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        test "does not assess Canada Tax when a valid QST ID is provided on a sale into Quebec" do
          expected_sales_tax = SalesTaxCalculation.zero_business_vat(100)

          actual_sales_tax = SalesTaxCalculator.new(product: create_product(user: @seller),
                                                    price_cents: 100,
                                                    buyer_location: { country: "CA", state: QUEBEC },
                                                    from_discover: true,
                                                    buyer_vat_id: "1002092821TQ0001").calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      describe "AU GST" do
        test "assesses GST in Australia" do
          product = create_product(user: @seller)
          expected_tax_rate = create_zip_tax_rate(country: "AU", state: nil, zip_code: nil, combined_rate: 0.10, is_seller_responsible: false)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 10,
                                                       zip_tax_rate: expected_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "AU" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        test "assesses GST for direct to customer sales in Australia" do
          product = create_physical_product(user: @seller)
          expected_tax_rate = create_zip_tax_rate(country: "AU", state: nil, zip_code: nil, combined_rate: 0.10, is_seller_responsible: false)

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
        setup do
          @tax_rate_2023 = create_zip_tax_rate(country: "SG", state: nil, zip_code: nil, combined_rate: 0.08, is_seller_responsible: false, applicable_years: [2023])
          @tax_rate_2024 = create_zip_tax_rate(country: "SG", state: nil, zip_code: nil, combined_rate: 0.09, is_seller_responsible: false, applicable_years: [2024])
        end

        test "assesses GST in Singapore in 2023" do
          travel_to(Time.find_zone("UTC").local(2023, 4, 1)) do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 8,
                                                         zip_tax_rate: @tax_rate_2023)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "SG" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        test "assesses GST in Singapore in 2024" do
          travel_to(Time.find_zone("UTC").local(2024, 4, 1)) do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 9,
                                                         zip_tax_rate: @tax_rate_2024)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "SG" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        test "assesses GST in Singapore after 2024 even if we did not add a tax rate for that year" do
          travel_to(Time.find_zone("UTC").local(2025, 4, 1)) do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 9,
                                                         zip_tax_rate: @tax_rate_2024)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "SG" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        test "assesses GST for direct to customer sales in Singapore" do
          product = create_physical_product(user: @seller)

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
        test "assesses VAT in Norway" do
          product = create_product(user: @seller)
          expected_tax_rate = create_zip_tax_rate(country: "NO", state: nil, zip_code: nil, combined_rate: 0.25, is_seller_responsible: false)
          create_zip_tax_rate(country: "NO", state: nil, zip_code: nil, combined_rate: 0.00, is_seller_responsible: false, is_epublication_rate: true)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 25,
                                                       zip_tax_rate: expected_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "NO" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        test "uses the epublication VAT rate for ebpublication products in Norway" do
          product = create_product(user: @seller, is_epublication: true)
          create_zip_tax_rate(country: "NO", state: nil, zip_code: nil, combined_rate: 0.25, is_seller_responsible: false, is_epublication_rate: false)
          expected_tax_rate = create_zip_tax_rate(country: "NO", state: nil, zip_code: nil, combined_rate: 0.00, is_seller_responsible: false, is_epublication_rate: true)

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
        setup do
          @standard_tax_rate = create_zip_tax_rate(country: "IS", state: nil, zip_code: nil, combined_rate: 0.24, is_seller_responsible: false)
        end

        attr_reader :standard_tax_rate
        setup do
          @epublication_tax_rate = create_zip_tax_rate(country: "IS", state: nil, zip_code: nil, combined_rate: 0.11, is_seller_responsible: false, is_epublication_rate: true)
        end

        attr_reader :epublication_tax_rate

        context "when collect_tax_is feature flag is off" do
          test "does not assess VAT in Iceland" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "IS" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end

          test "does not assess VAT for epublication products in Iceland" do
            product = create_product(user: @seller, is_epublication: true)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "IS" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_is feature flag is on" do
          setup do
            Feature.activate(:collect_tax_is)
          end

          test "assesses VAT in Iceland" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 24,
                                                         zip_tax_rate: standard_tax_rate)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "IS" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end

          test "uses the epublication VAT rate for epublication products in Iceland" do
            product = create_product(user: @seller, is_epublication: true)

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
        setup do
          @standard_tax_rate = create_zip_tax_rate(country: "JP", state: nil, zip_code: nil, combined_rate: 0.10, is_seller_responsible: false)
        end

        attr_reader :standard_tax_rate

        context "when collect_tax_jp feature flag is off" do
          test "does not assess CT in Japan" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "JP" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_jp feature flag is on" do
          setup do
            Feature.activate(:collect_tax_jp)
          end

          test "assesses CT in Japan" do
            product = create_product(user: @seller)

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
        setup do
          @standard_tax_rate = create_zip_tax_rate(country: "NZ", state: nil, zip_code: nil, combined_rate: 0.15, is_seller_responsible: false)
        end

        attr_reader :standard_tax_rate

        context "when collect_tax_nz feature flag is off" do
          test "does not assess GST in New Zealand" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "NZ" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_nz feature flag is on" do
          setup do
            Feature.activate(:collect_tax_nz)
          end

          test "assesses GST in New Zealand" do
            product = create_product(user: @seller)

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
        setup do
          @standard_tax_rate = create_zip_tax_rate(country: "ZA", state: nil, zip_code: nil, combined_rate: 0.15, is_seller_responsible: false)
        end

        attr_reader :standard_tax_rate

        context "when collect_tax_za feature flag is off" do
          test "does not assess VAT in South Africa" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "ZA" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_za feature flag is on" do
          setup do
            Feature.activate(:collect_tax_za)
          end

          test "assesses VAT in South Africa" do
            product = create_product(user: @seller)

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
        setup do
          @standard_tax_rate = create_zip_tax_rate(country: "CH", state: nil, zip_code: nil, combined_rate: 0.081, is_seller_responsible: false)
        end

        attr_reader :standard_tax_rate
        setup do
          @epublication_tax_rate = create_zip_tax_rate(country: "CH", state: nil, zip_code: nil, combined_rate: 0.026, is_seller_responsible: false, is_epublication_rate: true)
        end

        attr_reader :epublication_tax_rate

        context "when collect_tax_ch feature flag is off" do
          test "does not assess VAT in Switzerland" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "CH" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_ch feature flag is on" do
          setup do
            Feature.activate(:collect_tax_ch)
          end

          test "assesses standard VAT rate in Switzerland for regular products" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 8, # 8.1 rounded to whole cents at the calculation boundary
                                                         zip_tax_rate: standard_tax_rate)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "CH" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end

          test "assesses reduced VAT rate in Switzerland for epublications" do
            product = create_product(user: @seller, is_epublication: true)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 3, # 2.6 rounded to whole cents at the calculation boundary
                                                         zip_tax_rate: epublication_tax_rate)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "CH" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end
      end

      describe "United Arab Emirates VAT" do
        setup do
          @standard_tax_rate = create_zip_tax_rate(country: "AE", state: nil, zip_code: nil, combined_rate: 0.05, is_seller_responsible: false)
        end

        attr_reader :standard_tax_rate

        context "when collect_tax_ae feature flag is off" do
          test "does not assess VAT in United Arab Emirates" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "AE" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_ae feature flag is on" do
          setup do
            Feature.activate(:collect_tax_ae)
          end

          test "assesses VAT in United Arab Emirates" do
            product = create_product(user: @seller)

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
        setup do
          @standard_tax_rate = create_zip_tax_rate(country: "IN", state: nil, zip_code: nil, combined_rate: 0.18, is_seller_responsible: false)
        end

        attr_reader :standard_tax_rate

        context "when collect_tax_in feature flag is off" do
          test "does not assess GST in India" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "IN" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_in feature flag is on" do
          setup do
            Feature.activate(:collect_tax_in)
          end

          test "assesses GST in India" do
            product = create_product(user: @seller)

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
        setup do
          @standard_tax_rate = create_zip_tax_rate(country: "BH", state: nil, zip_code: nil, combined_rate: 0.10, is_seller_responsible: false)
        end

        attr_reader :standard_tax_rate

        context "when collect_tax_bh feature flag is off" do
          test "does not assess VAT in Bahrain" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "BH" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_bh feature flag is on" do
          setup do
            Feature.activate(:collect_tax_bh)
          end

          test "assesses VAT in Bahrain" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 10,
                                                         zip_tax_rate: standard_tax_rate)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "BH" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end

          test "does not assess VAT for physical products" do
            product = create_physical_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "BH" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end
      end

      describe "Belarus VAT" do
        setup do
          @standard_tax_rate = create_zip_tax_rate(country: "BY", state: nil, zip_code: nil, combined_rate: 0.20, is_seller_responsible: false)
        end

        attr_reader :standard_tax_rate

        context "when collect_tax_by feature flag is off" do
          test "does not assess VAT in Belarus" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "BY" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_by feature flag is on" do
          setup do
            Feature.activate(:collect_tax_by)
          end

          test "assesses VAT in Belarus" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 20,
                                                         zip_tax_rate: standard_tax_rate)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "BY" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end

          test "does not assess VAT for physical products" do
            product = create_physical_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "BY" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end
      end

      describe "Chile VAT" do
        setup do
          @standard_tax_rate = create_zip_tax_rate(country: "CL", state: nil, zip_code: nil, combined_rate: 0.19, is_seller_responsible: false)
        end

        attr_reader :standard_tax_rate

        context "when collect_tax_cl feature flag is off" do
          test "does not assess VAT in Chile" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "CL" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_cl feature flag is on" do
          setup do
            Feature.activate(:collect_tax_cl)
          end

          test "assesses VAT in Chile" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 19,
                                                         zip_tax_rate: standard_tax_rate)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "CL" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end

          test "does not assess VAT for physical products" do
            product = create_physical_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "CL" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end
      end

      describe "Colombia VAT" do
        setup do
          @standard_tax_rate = create_zip_tax_rate(country: "CO", state: nil, zip_code: nil, combined_rate: 0.19, is_seller_responsible: false)
        end

        attr_reader :standard_tax_rate

        context "when collect_tax_co feature flag is off" do
          test "does not assess VAT in Colombia" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "CO" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_co feature flag is on" do
          setup do
            Feature.activate(:collect_tax_co)
          end

          test "assesses VAT in Colombia" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 19,
                                                         zip_tax_rate: standard_tax_rate)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "CO" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end

          test "does not assess VAT for physical products" do
            product = create_physical_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "CO" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end
      end

      describe "Costa Rica VAT" do
        setup do
          @standard_tax_rate = create_zip_tax_rate(country: "CR", state: nil, zip_code: nil, combined_rate: 0.13, is_seller_responsible: false)
        end

        attr_reader :standard_tax_rate

        context "when collect_tax_cr feature flag is off" do
          test "does not assess VAT in Costa Rica" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "CR" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_cr feature flag is on" do
          setup do
            Feature.activate(:collect_tax_cr)
          end

          test "assesses VAT in Costa Rica" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 13,
                                                         zip_tax_rate: standard_tax_rate)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "CR" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end

          test "does not assess VAT for physical products" do
            product = create_physical_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "CR" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end
      end

      describe "Ecuador VAT" do
        setup do
          @standard_tax_rate = create_zip_tax_rate(country: "EC", state: nil, zip_code: nil, combined_rate: 0.12, is_seller_responsible: false)
        end

        attr_reader :standard_tax_rate

        context "when collect_tax_ec feature flag is off" do
          test "does not assess VAT in Ecuador" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "EC" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_ec feature flag is on" do
          setup do
            Feature.activate(:collect_tax_ec)
          end

          test "assesses VAT in Ecuador" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 12,
                                                         zip_tax_rate: standard_tax_rate)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "EC" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end

          test "does not assess VAT for physical products" do
            product = create_physical_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "EC" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end
      end

      describe "Egypt VAT" do
        setup do
          @standard_tax_rate = create_zip_tax_rate(country: "EG", state: nil, zip_code: nil, combined_rate: 0.14, is_seller_responsible: false)
        end

        attr_reader :standard_tax_rate

        context "when collect_tax_eg feature flag is off" do
          test "does not assess VAT in Egypt" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "EG" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_eg feature flag is on" do
          setup do
            Feature.activate(:collect_tax_eg)
          end

          test "assesses VAT in Egypt" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 14,
                                                         zip_tax_rate: standard_tax_rate)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "EG" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end

          test "does not assess VAT for physical products" do
            product = create_physical_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "EG" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end
      end

      describe "Georgia VAT" do
        setup do
          @standard_tax_rate = create_zip_tax_rate(country: "GE", state: nil, zip_code: nil, combined_rate: 0.18, is_seller_responsible: false)
        end

        attr_reader :standard_tax_rate

        context "when collect_tax_ge feature flag is off" do
          test "does not assess VAT in Georgia" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "GE" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_ge feature flag is on" do
          setup do
            Feature.activate(:collect_tax_ge)
          end

          test "assesses VAT in Georgia" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 18,
                                                         zip_tax_rate: standard_tax_rate)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "GE" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end

          test "does not assess VAT for physical products" do
            product = create_physical_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "GE" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end
      end

      describe "Kazakhstan VAT" do
        setup do
          @standard_tax_rate = create_zip_tax_rate(country: "KZ", state: nil, zip_code: nil, combined_rate: 0.12, is_seller_responsible: false)
        end

        attr_reader :standard_tax_rate

        context "when collect_tax_kz feature flag is off" do
          test "does not assess VAT in Kazakhstan" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "KZ" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_kz feature flag is on" do
          setup do
            Feature.activate(:collect_tax_kz)
          end

          test "assesses VAT in Kazakhstan" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 12,
                                                         zip_tax_rate: standard_tax_rate)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "KZ" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end

          test "does not assess VAT for physical products" do
            product = create_physical_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "KZ" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end
      end

      describe "Kenya VAT" do
        setup do
          @standard_tax_rate = create_zip_tax_rate(country: "KE", state: nil, zip_code: nil, combined_rate: 0.16, is_seller_responsible: false)
        end

        attr_reader :standard_tax_rate

        context "when collect_tax_ke feature flag is off" do
          test "does not assess VAT in Kenya" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "KE" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_ke feature flag is on" do
          setup do
            Feature.activate(:collect_tax_ke)
          end

          test "assesses VAT in Kenya" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 16,
                                                         zip_tax_rate: standard_tax_rate)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "KE" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end

          test "does not assess VAT for physical products" do
            product = create_physical_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "KE" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end
      end

      describe "Malaysia Service Tax" do
        setup do
          @standard_tax_rate = create_zip_tax_rate(country: "MY", state: nil, zip_code: nil, combined_rate: 0.06, is_seller_responsible: false)
        end

        attr_reader :standard_tax_rate

        context "when collect_tax_my feature flag is off" do
          test "does not assess Service Tax in Malaysia" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "MY" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_my feature flag is on" do
          setup do
            Feature.activate(:collect_tax_my)
          end

          test "assesses Service Tax in Malaysia" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 6,
                                                         zip_tax_rate: standard_tax_rate)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "MY" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end

          test "does not assess Service Tax for physical products" do
            product = create_physical_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "MY" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end
      end

      describe "Mexico VAT" do
        test "does not assess VAT in Mexico" do
          create_zip_tax_rate(country: "MX", state: nil, zip_code: nil, combined_rate: 0.16, is_seller_responsible: false)
          product = create_product(user: @seller)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "MX" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end

      describe "Moldova VAT" do
        def standard_tax_rate
          @standard_tax_rate ||= create_zip_tax_rate(country: "MD", state: nil, zip_code: nil, combined_rate: 0.20, is_seller_responsible: false)
        end

        context "when collect_tax_md feature flag is off" do
          test "does not assess VAT" do
            product = create_product(user: @seller)
            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "MD" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_md feature flag is on" do
          setup do
            Feature.activate(:collect_tax_md)
          end

          test "assesses VAT in Moldova" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 20,
                                                         zip_tax_rate: standard_tax_rate)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "MD" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end

          test "does not assess VAT for physical products" do
            product = create_physical_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "MD" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end
      end

      describe "Morocco VAT" do
        def standard_tax_rate
          @standard_tax_rate ||= create_zip_tax_rate(country: "MA", state: nil, zip_code: nil, combined_rate: 0.20, is_seller_responsible: false)
        end

        context "when collect_tax_ma feature flag is off" do
          test "does not assess VAT" do
            product = create_product(user: @seller)
            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "MA" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_ma feature flag is on" do
          setup do
            Feature.activate(:collect_tax_ma)
          end

          test "assesses VAT in Morocco" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 20,
                                                         zip_tax_rate: standard_tax_rate)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "MA" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end

          test "does not assess VAT for physical products" do
            product = create_physical_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "MA" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end
      end

      describe "Nigeria VAT" do
        def standard_tax_rate
          @standard_tax_rate ||= create_zip_tax_rate(country: "NG", state: nil, zip_code: nil, combined_rate: 0.075, is_seller_responsible: false)
        end

        context "when collect_tax_ng feature flag is off" do
          test "does not assess VAT" do
            product = create_product(user: @seller)
            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "NG" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_ng feature flag is on" do
          setup do
            Feature.activate(:collect_tax_ng)
          end

          test "assesses VAT in Nigeria" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 8, # 7.5 rounded to whole cents at the calculation boundary
                                                         zip_tax_rate: standard_tax_rate)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "NG" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end

          test "does not assess VAT for physical products" do
            product = create_physical_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "NG" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end
      end

      describe "Oman VAT" do
        def standard_tax_rate
          @standard_tax_rate ||= create_zip_tax_rate(country: "OM", state: nil, zip_code: nil, combined_rate: 0.05, is_seller_responsible: false)
        end

        context "when collect_tax_om feature flag is off" do
          test "does not assess VAT" do
            product = create_product(user: @seller)
            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "OM" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_om feature flag is on" do
          setup do
            Feature.activate(:collect_tax_om)
          end

          test "assesses VAT in Oman" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 5,
                                                         zip_tax_rate: standard_tax_rate)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "OM" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end

          test "does not assess VAT for physical products" do
            product = create_physical_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "OM" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end
      end

      describe "Russia VAT" do
        def standard_tax_rate
          @standard_tax_rate ||= create_zip_tax_rate(country: "RU", state: nil, zip_code: nil, combined_rate: 0.20, is_seller_responsible: false)
        end

        context "when collect_tax_ru feature flag is off" do
          test "does not assess VAT" do
            product = create_product(user: @seller)
            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "RU" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_ru feature flag is on" do
          setup do
            Feature.activate(:collect_tax_ru)
          end

          test "assesses VAT in Russia" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 20,
                                                         zip_tax_rate: standard_tax_rate)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "RU" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end

          test "does not assess VAT for physical products" do
            product = create_physical_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "RU" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end
      end

      describe "Saudi Arabia VAT" do
        def standard_tax_rate
          @standard_tax_rate ||= create_zip_tax_rate(country: "SA", state: nil, zip_code: nil, combined_rate: 0.15, is_seller_responsible: false)
        end

        context "when collect_tax_sa feature flag is off" do
          test "does not assess VAT" do
            product = create_product(user: @seller)
            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "SA" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_sa feature flag is on" do
          setup do
            Feature.activate(:collect_tax_sa)
          end

          test "assesses VAT in Saudi Arabia" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 15,
                                                         zip_tax_rate: standard_tax_rate)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "SA" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end

          test "does not assess VAT for physical products" do
            product = create_physical_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "SA" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end
      end

      describe "Serbia VAT" do
        def standard_tax_rate
          @standard_tax_rate ||= create_zip_tax_rate(country: "RS", state: nil, zip_code: nil, combined_rate: 0.20, is_seller_responsible: false)
        end

        context "when collect_tax_rs feature flag is off" do
          test "does not assess VAT" do
            product = create_product(user: @seller)
            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "RS" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_rs feature flag is on" do
          setup do
            Feature.activate(:collect_tax_rs)
          end

          test "assesses VAT in Serbia" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 20,
                                                         zip_tax_rate: standard_tax_rate)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "RS" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end

          test "does not assess VAT for physical products" do
            product = create_physical_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "RS" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end
      end

      describe "South Korea VAT" do
        def standard_tax_rate
          @standard_tax_rate ||= create_zip_tax_rate(country: "KR", state: nil, zip_code: nil, combined_rate: 0.10, is_seller_responsible: false)
        end

        context "when collect_tax_kr feature flag is off" do
          test "does not assess VAT" do
            product = create_product(user: @seller)
            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "KR" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_kr feature flag is on" do
          setup do
            Feature.activate(:collect_tax_kr)
          end

          test "assesses VAT in South Korea" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 10,
                                                         zip_tax_rate: standard_tax_rate)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "KR" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end

          test "does not assess VAT for physical products" do
            product = create_physical_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "KR" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end
      end

      describe "Tanzania VAT" do
        def standard_tax_rate
          @standard_tax_rate ||= create_zip_tax_rate(country: "TZ", state: nil, zip_code: nil, combined_rate: 0.18, is_seller_responsible: false)
        end

        context "when collect_tax_tz feature flag is off" do
          test "does not assess VAT" do
            product = create_product(user: @seller)
            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "TZ" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_tz feature flag is on" do
          setup do
            Feature.activate(:collect_tax_tz)
          end

          test "assesses VAT in Tanzania" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 18,
                                                         zip_tax_rate: standard_tax_rate)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "TZ" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end

          test "does not assess VAT for physical products" do
            product = create_physical_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "TZ" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end
      end

      describe "Thailand VAT" do
        def standard_tax_rate
          @standard_tax_rate ||= create_zip_tax_rate(country: "TH", state: nil, zip_code: nil, combined_rate: 0.07, is_seller_responsible: false)
        end

        context "when collect_tax_th feature flag is off" do
          test "does not assess VAT" do
            product = create_product(user: @seller)
            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "TH" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_th feature flag is on" do
          setup do
            Feature.activate(:collect_tax_th)
          end

          test "assesses VAT in Thailand" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 7,
                                                         zip_tax_rate: standard_tax_rate)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "TH" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end

          test "does not assess VAT for physical products" do
            product = create_physical_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "TH" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end
      end

      describe "Turkey VAT" do
        def standard_tax_rate
          @standard_tax_rate ||= create_zip_tax_rate(country: "TR", state: nil, zip_code: nil, combined_rate: 0.20, is_seller_responsible: false)
        end

        context "when collect_tax_tr feature flag is off" do
          test "does not assess VAT" do
            product = create_product(user: @seller)
            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "TR" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_tr feature flag is on" do
          setup do
            Feature.activate(:collect_tax_tr)
          end

          test "assesses VAT in Turkey" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 20,
                                                         zip_tax_rate: standard_tax_rate)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "TR" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end

          test "does not assess VAT for physical products" do
            product = create_physical_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "TR" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end
      end

      describe "Ukraine VAT" do
        def standard_tax_rate
          @standard_tax_rate ||= create_zip_tax_rate(country: "UA", state: nil, zip_code: nil, combined_rate: 0.20, is_seller_responsible: false)
        end

        context "when collect_tax_ua feature flag is off" do
          test "does not assess VAT" do
            product = create_product(user: @seller)
            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "UA" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_ua feature flag is on" do
          setup do
            Feature.activate(:collect_tax_ua)
          end

          test "assesses VAT in Ukraine" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 20,
                                                         zip_tax_rate: standard_tax_rate)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "UA" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end

          test "does not assess VAT for physical products" do
            product = create_physical_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "UA" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end
      end

      describe "Uzbekistan VAT" do
        def standard_tax_rate
          @standard_tax_rate ||= create_zip_tax_rate(country: "UZ", state: nil, zip_code: nil, combined_rate: 0.15, is_seller_responsible: false)
        end

        context "when collect_tax_uz feature flag is off" do
          test "does not assess VAT" do
            product = create_product(user: @seller)
            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "UZ" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_uz feature flag is on" do
          setup do
            Feature.activate(:collect_tax_uz)
          end

          test "assesses VAT in Uzbekistan" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 15,
                                                         zip_tax_rate: standard_tax_rate)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "UZ" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end

          test "does not assess VAT for physical products" do
            product = create_physical_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "UZ" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end
      end

      describe "Vietnam VAT" do
        def standard_tax_rate
          @standard_tax_rate ||= create_zip_tax_rate(country: "VN", state: nil, zip_code: nil, combined_rate: 0.10, is_seller_responsible: false)
        end

        context "when collect_tax_vn feature flag is off" do
          test "does not assess VAT" do
            product = create_product(user: @seller)
            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "VN" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end

        context "when collect_tax_vn feature flag is on" do
          setup do
            Feature.activate(:collect_tax_vn)
          end

          test "assesses VAT in Vietnam" do
            product = create_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                         tax_cents: 10,
                                                         zip_tax_rate: standard_tax_rate)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "VN" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end

          test "does not assess VAT for physical products" do
            product = create_physical_product(user: @seller)

            expected_sales_tax = SalesTaxCalculation.zero_tax(100)

            actual_sales_tax = SalesTaxCalculator.new(product:,
                                                      price_cents: 100,
                                                      buyer_location: { country: "VN" }).calculate

            compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
          end
        end
      end

      describe "EU VAT" do
        setup do
          @seller.collect_eu_vat = true
          @seller.is_eu_vat_exclusive = false
          @seller.save!

          create_zip_tax_rate(country: "ES", state: nil, zip_code: nil, combined_rate: 0.10, is_seller_responsible: true)
        end

        test "does not assess VAT in VAT-exempt EU territories" do
          expect_zero_tax_for(country: "ES", ip_address: "193.145.138.32") # Canary Islands
          expect_zero_tax_for(country: "ES", ip_address: "193.145.147.158") # Canary Islands
        end

        test "assesses VAT in EU country" do
          product = create_product(user: @seller)
          expected_tax_rate = create_zip_tax_rate(country: "IT", state: nil, zip_code: nil, combined_rate: 0.22, is_seller_responsible: false)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 22,
                                                       zip_tax_rate: expected_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "IT" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        test "does not assess VAT in EU country if seller has a Brazilian Stripe Connect account" do
          product = create_product(user: @seller)
          @seller.update!(check_merchant_account_is_linked: true)
          create_merchant_account_stripe_connect(user: @seller, country: "BR", charge_processor_merchant_id: "acct_1QADdCGy0w4tFIUe")
          create_zip_tax_rate(country: "IT", state: nil, zip_code: nil, combined_rate: 0.22, is_seller_responsible: false)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 0,
                                                       zip_tax_rate: nil)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "IT" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        test "does not assess VAT for physical products shipped to an EU country" do
          product = create_physical_product(user: @seller)
          create_zip_tax_rate(country: "IT", state: nil, zip_code: nil, combined_rate: 0.22, is_seller_responsible: false)

          expected_sales_tax = SalesTaxCalculation.zero_tax(100)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "IT" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        test "uses the standard VAT rate for non e-publication products in the EU" do
          product = create_product(user: @seller)
          create_zip_tax_rate(country: "AT", zip_code: nil, state: nil, combined_rate: 0.10, is_seller_responsible: false, is_epublication_rate: true)
          expected_tax_rate = create_zip_tax_rate(country: "AT", zip_code: nil, state: nil, combined_rate: 0.20, is_seller_responsible: false, is_epublication_rate: false)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 20,
                                                       zip_tax_rate: expected_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "AT" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        test "uses the epublication VAT rate for ebpublication products in the EU" do
          product = create_product(user: @seller, is_epublication: true)
          create_zip_tax_rate(country: "AT", zip_code: nil, state: nil, combined_rate: 0.20, is_seller_responsible: false, is_epublication_rate: false)
          expected_tax_rate = create_zip_tax_rate(country: "AT", zip_code: nil, state: nil, combined_rate: 0.10, is_seller_responsible: false, is_epublication_rate: true)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 10,
                                                       zip_tax_rate: expected_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "AT" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        test "uses the epublication VAT rate for ebpublication products in the EU even when the VAT rate is zero" do
          product = create_product(user: @seller, is_epublication: true)
          create_zip_tax_rate(country: "GB", zip_code: nil, state: nil, combined_rate: 0.20, is_seller_responsible: false, is_epublication_rate: false)
          expected_tax_rate = create_zip_tax_rate(country: "GB", zip_code: nil, state: nil, combined_rate: 0.00, is_seller_responsible: false, is_epublication_rate: true)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 0,
                                                       zip_tax_rate: expected_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product:,
                                                    price_cents: 100,
                                                    buyer_location: { country: "GB" }).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        def expect_zero_tax_for(buyer_location)
          actual_sales_tax = SalesTaxCalculator.new(product: create_product(user: @seller),
                                                    price_cents: 100,
                                                    buyer_location:).calculate

          compare_calculations(expected: SalesTaxCalculation.zero_tax(100), actual: actual_sales_tax)
        end
      end

      describe "EU VAT controls for merchant migrated account" do
        setup do
          Feature.activate_user(:merchant_migration, @seller)
        end

        teardown do
          Feature.deactivate_user(:merchant_migration, @seller)
        end

        test "ignores seller taxable regions and overrides inclusive taxation when applicable (non-US)" do
          @seller.collect_eu_vat = true
          @seller.is_eu_vat_exclusive = true
          @seller.save!

          expected_tax_rate = create_zip_tax_rate(country: "ES", zip_code: nil, state: nil, combined_rate: 0.21, is_seller_responsible: false)

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 21,
                                                       zip_tax_rate: expected_tax_rate)

          actual_sales_tax = SalesTaxCalculator.new(product: create_product(user: @seller),
                                                    price_cents: 100,
                                                    buyer_location: { country: "ES" },).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end

        test "ignores seller taxable regions and ignores VAT when applicable (non-US)" do
          @seller.collect_eu_vat = false
          @seller.save!

          expected_sales_tax = SalesTaxCalculation.new(price_cents: 100,
                                                       tax_cents: 0,
                                                       zip_tax_rate: nil)

          actual_sales_tax = SalesTaxCalculator.new(product: create_product(user: @seller),
                                                    price_cents: 100,
                                                    buyer_location: { country: "ES" },).calculate

          compare_calculations(expected: expected_sales_tax, actual: actual_sales_tax)
        end
      end
    end

    def compare_calculations(expected:, actual:)
      assert_kind_of SalesTaxCalculation, expected
      assert_kind_of SalesTaxCalculation, actual

      assert_equal expected.price_cents, actual.price_cents
      assert_equal expected.tax_cents, actual.tax_cents
      assert_equal_or_nil expected.zip_tax_rate, actual.zip_tax_rate
      assert_equal expected.used_taxjar, actual.used_taxjar
      assert_equal_or_nil expected.taxjar_info, actual.taxjar_info
    end

    def assert_equal_or_nil(expected, actual)
      expected.nil? ? assert_nil(actual) : assert_equal(expected, actual)
    end
  end
end
