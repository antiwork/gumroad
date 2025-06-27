# frozen_string_literal: true

class Purchase::TaxCalculationService
  def initialize(purchase)
    @purchase = purchase
  end

  def call
    return unless should_calculate_taxes?

    customer_country = @purchase.country_or_ip_country
    country_code = Compliance::Countries.find_by_name(customer_country)&.alpha2

    return unless tax_calculation_required?(customer_country, country_code)

    calculator = build_tax_calculator(customer_country, country_code)
    tax_calculation = calculator.calculate

    apply_tax_calculation(tax_calculation)

    @purchase.was_purchase_taxable = @purchase.gumroad_tax_cents > 0 || @purchase.tax_cents > 0
    @purchase.was_tax_excluded_from_price = true
  end

  private
    def should_calculate_taxes?
      @purchase.price_cents.present? &&
        @purchase.price_cents != 0 &&
        @purchase.tax_location_valid? &&
        !@purchase.seller.has_brazilian_stripe_connect_account?
    end

    def tax_calculation_required?(customer_country, country_code)
      in_eu_country = Compliance::Countries::EU_VAT_APPLICABLE_COUNTRY_CODES.include?(country_code)
      in_australia = customer_country == Compliance::Countries::AUS.common_name
      in_singapore = customer_country == Compliance::Countries::SGP.common_name
      in_norway = customer_country == Compliance::Countries::NOR.common_name
      in_other_taxable_country = (Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_ALL_PRODUCTS).include?(country_code)
      in_other_taxable_country ||= (Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_DIGITAL_PRODUCTS).include?(country_code) && !@purchase.link.is_physical?

      calculator = build_tax_calculator(customer_country, country_code)

      in_eu_country ||
        in_australia ||
        in_singapore ||
        in_norway ||
        (in_other_taxable_country && Feature.active?("collect_tax_#{country_code.downcase}")) ||
        calculator.is_us_taxable_state ||
        calculator.is_ca_taxable
    end

    def build_tax_calculator(customer_country, country_code)
      # Will return zip from shipping information if available before guessing from IP.
      # Shipping info is saved in Purchase during its creation in the Purchases controller
      # See best_guess_zip for more detail on parsing / guessing zip
      postal_code = @purchase.best_guess_zip

      SalesTaxCalculator.new(
        product: @purchase.link,
        price_cents: @purchase.price_cents,
        shipping_cents: @purchase.shipping_cents.to_i,
        quantity: @purchase.quantity,
        buyer_location: {
          postal_code: postal_code,
          country: country_code,
          state: @purchase.state,
          ip_address: @purchase.ip_address
        },
        buyer_vat_id: @purchase.business_vat_id,
        from_discover: @purchase.was_product_recommended
      )
    end

    def apply_tax_calculation(tax_calculation)
      if tax_calculation.zip_tax_rate.present?
        @purchase.zip_tax_rate = tax_calculation.zip_tax_rate

        if tax_calculation.zip_tax_rate.is_seller_responsible
          @purchase.tax_cents = tax_calculation.tax_cents
        else
          @purchase.gumroad_tax_cents = tax_calculation.tax_cents
        end
      elsif tax_calculation.used_taxjar
        if tax_calculation.gumroad_is_mpf
          @purchase.gumroad_tax_cents = tax_calculation.tax_cents
        else
          @purchase.tax_cents = tax_calculation.tax_cents
        end

        update_taxjar_info(tax_calculation) if tax_calculation.taxjar_info.present?
      end
    end

    def update_taxjar_info(tax_calculation)
      taxjar_info = @purchase.purchase_taxjar_info || @purchase.build_purchase_taxjar_info

      taxjar_info.tap do |info|
        info.combined_tax_rate = tax_calculation.taxjar_info[:combined_tax_rate]
        info.state_tax_rate = tax_calculation.taxjar_info[:state_tax_rate]
        info.county_tax_rate = tax_calculation.taxjar_info[:county_tax_rate]
        info.city_tax_rate = tax_calculation.taxjar_info[:city_tax_rate]
        info.gst_tax_rate = tax_calculation.taxjar_info[:gst_tax_rate]
        info.pst_tax_rate = tax_calculation.taxjar_info[:pst_tax_rate]
        info.qst_tax_rate = tax_calculation.taxjar_info[:qst_tax_rate]
        info.jurisdiction_state = tax_calculation.taxjar_info[:jurisdiction_state]
        info.jurisdiction_county = tax_calculation.taxjar_info[:jurisdiction_county]
        info.jurisdiction_city = tax_calculation.taxjar_info[:jurisdiction_city]
        info.save!
      end
    end
end
