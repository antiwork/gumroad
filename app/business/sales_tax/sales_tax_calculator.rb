# frozen_string_literal: true

require_relative "../../../lib/utilities/geo_ip"

class SalesTaxCalculator
  attr_accessor :tax_rate, :product, :price_cents, :shipping_cents, :quantity, :buyer_location, :buyer_vat_id, :state, :is_us_taxable_state, :is_ca_taxable, :is_quebec

  def initialize(product:, price_cents:, shipping_cents: 0, quantity: 1, buyer_location:, buyer_vat_id: nil, from_discover: false)
    @tax_rate = nil
    @product = product
    @price_cents = price_cents
    @shipping_cents = shipping_cents
    @quantity = quantity
    @buyer_location = buyer_location
    @buyer_vat_id = buyer_vat_id
    validate
    @state = if buyer_location[:country] == Compliance::Countries::USA.alpha2
      UsZipCodes.identify_state_code(buyer_location[:postal_code])
    elsif buyer_location[:country] == Compliance::Countries::CAN.alpha2
      buyer_location[:state]
    end

    @is_us_taxable_state = buyer_location[:country] == Compliance::Countries::USA.alpha2 && @state.present? && Compliance::Countries.taxable_state?(@state)
    @is_ca_taxable = buyer_location[:country] == Compliance::Countries::CAN.alpha2 && @state.present?

    @is_quebec = is_ca_taxable && @state == QUEBEC
  end

  def calculate
    return SalesTaxCalculation.zero_tax(price_cents) if price_cents == 0

    return SalesTaxCalculation.zero_tax(price_cents) if product.user.has_brazilian_stripe_connect_account?

    return SalesTaxCalculation.zero_business_vat(price_cents) if is_vat_id_valid?

    sales_tax_calculation = calculate_with_taxjar
    return sales_tax_calculation if sales_tax_calculation

    calculate_with_lookup_table

    return SalesTaxCalculation.zero_tax(price_cents) if tax_rate.nil?
    return SalesTaxCalculation.zero_tax(price_cents) unless tax_eligible?

    tax_amount_cents = price_cents * tax_rate.combined_rate
    SalesTaxCalculation.new(price_cents:,
                            tax_cents: tax_amount_cents,
                            zip_tax_rate: tax_rate,
                            business_vat_status: @buyer_vat_id.present? ? :invalid : nil,
                            is_quebec:)
  end

  private
    def calculate_with_taxjar
      return unless is_us_taxable_state || is_ca_taxable

      origin = {
        country: GumroadAddress::COUNTRY.alpha2,
        state: GumroadAddress::STATE,
        zip: GumroadAddress::ZIP
      }

      destination = {
        country: buyer_location[:country],
        state:
      }

      destination[:zip] = buyer_location[:postal_code] if buyer_location[:country] == Compliance::Countries::USA.alpha2

      nexus_address = {
        country: buyer_location[:country],
        state:
      }

      product_tax_code = Link::NATIVE_TYPES_TO_TAX_CODE[product.native_type]

      unit_price_dollars = price_cents / 100.0 / quantity
      shipping_dollars = shipping_cents / 100.0

      begin
        taxjar_response_json = TaxjarApi.new.calculate_tax_for_order(origin:,
                                                                     destination:,
                                                                     nexus_address:,
                                                                     quantity:,
                                                                     product_tax_code:,
                                                                     unit_price_dollars:,
                                                                     shipping_dollars:)
      rescue *TaxjarErrors::CLIENT, *TaxjarErrors::SERVER
        return
      end

      taxjar_info = {
        combined_tax_rate: taxjar_response_json["rate"],
        state_tax_rate: taxjar_response_json["breakdown"]["state_tax_rate"],
        county_tax_rate: taxjar_response_json["breakdown"]["county_tax_rate"],
        city_tax_rate: taxjar_response_json["breakdown"]["city_tax_rate"],
        gst_tax_rate: taxjar_response_json["breakdown"]["gst_tax_rate"],
        pst_tax_rate: taxjar_response_json["breakdown"]["pst_tax_rate"],
        qst_tax_rate: taxjar_response_json["breakdown"]["qst_tax_rate"],
        jurisdiction_state: taxjar_response_json["jurisdictions"]["state"],
        jurisdiction_county: taxjar_response_json["jurisdictions"]["county"],
        jurisdiction_city: taxjar_response_json["jurisdictions"]["city"]
      }

      tax_amount_cents = (taxjar_response_json["amount_to_collect"] * 100.0).round.to_d

      SalesTaxCalculation.new(price_cents:,
                              tax_cents: tax_amount_cents,
                              zip_tax_rate: nil,
                              business_vat_status: buyer_vat_id.present? ? :invalid : nil,
                              used_taxjar: true,
                              taxjar_info:,
                              gumroad_is_mpf: is_us_taxable_state || is_ca_taxable,
                              is_quebec:)
    end

    def validate
      raise SalesTaxCalculatorValidationError, "Price (cents) should be an Integer" unless @price_cents.is_a? Integer
      raise SalesTaxCalculatorValidationError, "Buyer Location should be a Hash" unless @buyer_location.is_a? Hash
      raise SalesTaxCalculatorValidationError, "Product should be a Link instance" unless @product.is_a? Link
    end

    def is_vat_id_valid?
      RegionalVatIdValidationService.new(
        @buyer_vat_id,
        country_code: buyer_location&.dig(:country),
        state_code: state
      ).process
    end

    # Internal: Determine the sales tax to be levied if applicable.
    #
    # product_external_id - Product's external ID , used to retrieve metadata from cache.
    # buyer_location - Buyer location information to determine tax rate.
    def calculate_with_lookup_table
      return if tax_rate.present?
      return if product.nil?

      country_code = buyer_location[:country]
      return if country_code.blank?

      tax_rate =
        if is_us_taxable_state
          ZipTaxRate.alive
            .where(country: Compliance::Countries::USA.alpha2, state:)
            .not_is_seller_responsible
            .not_is_epublication_rate
            .first
        elsif Compliance::Countries::EU_VAT_APPLICABLE_COUNTRY_CODES.include?(buyer_location[:country])
          zip_tax_rates = ZipTaxRate.alive
            .where(country: country_code)
            .not_is_seller_responsible
          zip_tax_rates = product.is_epublication? ? zip_tax_rates.is_epublication_rate : zip_tax_rates.not_is_epublication_rate
          zip_tax_rates.first
        elsif Compliance::Countries::AUS.alpha2 == buyer_location[:country]
          ZipTaxRate.alive
            .where(country: Compliance::Countries::AUS.alpha2)
            .not_is_seller_responsible
            .not_is_epublication_rate
            .first
        elsif Compliance::Countries::SGP.alpha2 == country_code
          rates = ZipTaxRate.alive
            .where(country: Compliance::Countries::SGP.alpha2)
            .not_is_seller_responsible
            .not_is_epublication_rate
            .order(created_at: :asc)
            .to_a

          rates.find { |rate| rate.applicable_years.include?(Time.current.year) } || rates.sort_by { |rate| rate.applicable_years.max }.last
        elsif Compliance::Countries::NOR.alpha2 == country_code
          zip_tax_rates = ZipTaxRate.alive
            .where(country: Compliance::Countries::NOR.alpha2)
            .not_is_seller_responsible
          zip_tax_rates = product.is_epublication? ? zip_tax_rates.is_epublication_rate : zip_tax_rates.not_is_epublication_rate
          zip_tax_rates.first
        elsif Compliance::Countries::CAN.alpha2 == country_code
          ZipTaxRate.alive
            .where(country: Compliance::Countries::CAN.alpha2, state:)
            .not_is_seller_responsible
            .not_is_epublication_rate
            .first
        else
          feature_flag = "collect_tax_#{country_code.downcase}"

          if Feature.active?(feature_flag) && (Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_ALL_PRODUCTS + Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_DIGITAL_PRODUCTS).include?(country_code)
            # Countries that have special e-publication rates
            special_epublication_countries = [
              Compliance::Countries::ISL.alpha2,
              Compliance::Countries::CHE.alpha2,
              Compliance::Countries::MEX.alpha2
            ]

            zip_tax_rates = ZipTaxRate.alive
              .where(country: country_code)
              .not_is_seller_responsible

            if special_epublication_countries.include?(country_code)
              zip_tax_rates = product.is_epublication? ? zip_tax_rates.is_epublication_rate : zip_tax_rates.not_is_epublication_rate
            end

            zip_tax_rates.first
          end
        end

      return unless tax_rate

      return if is_vat_exempt?(tax_rate)

      @tax_rate = tax_rate
    end

    # Certain territories of EU countries are exempt from VAT
    # https://docs.recurly.com/docs/eu-vat-2015#section-eu-territories-that-don-t-require-vat
    # This only supports Canary Islands for now, but should be expanded in the future.
    def is_vat_exempt?(tax_rate)
      return unless tax_rate
      if Compliance::Countries::EU_VAT_APPLICABLE_COUNTRY_CODES.include?(tax_rate.country)
        if tax_rate.country == "ES"
          if buyer_location[:ip_address] && (geocode = GEOIP.city(buyer_location[:ip_address]) rescue nil)
            geocode.country.iso_code == "ES" &&
              geocode.subdivisions.collect(&:name).any? { |division_name| Compliance::VAT_EXEMPT_REGIONS.include?(division_name) }
          end
        end
      end
    end

    def tax_eligible?
      product_tax_eligible = product.is_physical && tax_rate.country == Compliance::Countries::USA.alpha2
      product_tax_eligible ||= Compliance::Countries::EU_VAT_APPLICABLE_COUNTRY_CODES.include?(tax_rate.country)
      product_tax_eligible ||= tax_rate.country == Compliance::Countries::AUS.alpha2
      product_tax_eligible ||= tax_rate.country == Compliance::Countries::SGP.alpha2
      product_tax_eligible ||= tax_rate.country == Compliance::Countries::NOR.alpha2

      Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_ALL_PRODUCTS.each do |country_code|
        product_tax_eligible ||= tax_rate.country == country_code && Feature.active?("collect_tax_#{country_code.downcase}")
      end

      Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_DIGITAL_PRODUCTS.each do |country_code|
        product_tax_eligible ||= tax_rate.country == country_code && !product.is_physical && Feature.active?("collect_tax_#{country_code.downcase}")
      end

      product_tax_eligible ||= is_us_taxable_state
      product_tax_eligible ||= is_ca_taxable
      product_tax_eligible || tax_rate.user_id.present?
    end

    def seller
      @_seller ||= product&.user
    end
end
