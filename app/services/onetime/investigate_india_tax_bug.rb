# frozen_string_literal: true

# Investigation script for India tax bug (GitHub issue #2183)
#
# This script finds India purchases with 0% tax despite no Tax ID being provided and checks whether
# they match the pre-fix "location verification" bailout (selected taxable country, but IP/card in
# non-taxable countries).
#
# NOTE: This script is read-only (no creates/updates/deletes).
#
# Usage:
#   Onetime::InvestigateIndiaTaxBug.run
#
# Output is written to: log/investigate_india_tax_bug_YYYY-MM-DD_HH-MM-SS.log
#
class Onetime::InvestigateIndiaTaxBug < Onetime::Base
  MONTHS_TO_SEARCH = 6
  ANALYZE_LIMIT = 100
  EXAMPLES_LIMIT = 5

  INDIA_COUNTRY_CODE = "IN"
  COLLECT_TAX_IN_FEATURE = "collect_tax_in"

  def self.run
    new.process_with_logging
  end

  def process
    Rails.logger.info "=" * 80
    Rails.logger.info "INVESTIGATING INDIA TAX BUG - GitHub Issue #2183"
    Rails.logger.info "=" * 80

    check_feature_flag
    check_zip_tax_rate
    find_buggy_purchases
  end

  private
    def check_feature_flag
      Rails.logger.info "\n### FEATURE FLAG CHECK ###"
      flag_active = Feature.active?(COLLECT_TAX_IN_FEATURE)
      Rails.logger.info "#{COLLECT_TAX_IN_FEATURE} feature flag is: #{flag_active ? 'ACTIVE' : 'INACTIVE'}"

      if !flag_active
        Rails.logger.warn "WARNING: Feature flag is OFF. India tax collection is disabled!"
      end
    end

    def check_zip_tax_rate
      Rails.logger.info "\n### ZIP TAX RATE CHECK ###"
      india_tax_rates = ZipTaxRate.alive.where(country: INDIA_COUNTRY_CODE)

      if india_tax_rates.empty?
        Rails.logger.error "ERROR: No ZipTaxRate found for India (country: #{INDIA_COUNTRY_CODE})"
      else
        Rails.logger.info "Found #{india_tax_rates.size} ZipTaxRate records for India."
        india_tax_rates.each do |rate|
          Rails.logger.info "  ID=#{rate.id} rate=#{(rate.combined_rate * 100).round(2)}% seller_responsible=#{rate.is_seller_responsible}"
        end
      end
    end

    def find_buggy_purchases
      Rails.logger.info "\n### BUGGY PURCHASES (Last #{MONTHS_TO_SEARCH} months) ###"

      buggy_purchases = buggy_purchases_scope
      total_count = buggy_purchases.count
      Rails.logger.info "Total buggy purchases found: #{total_count}"

      if total_count == 0
        Rails.logger.info "No buggy purchases found. Either the bug doesn't exist or it was already fixed."
        return
      end

      purchases_for_analysis = buggy_purchases.limit(ANALYZE_LIMIT).includes(:purchase_sales_tax_info, :link)
      analyze_patterns(purchases_for_analysis)
      show_examples(purchases_for_analysis.first(EXAMPLES_LIMIT))
    end

    def show_examples(purchases)
      Rails.logger.info "\n### EXAMPLES (first #{purchases.size}) ###"

      purchases.each_with_index do |purchase, index|
        info = purchase.purchase_sales_tax_info
        product = purchase.link

        Rails.logger.info "-" * 60
        Rails.logger.info "Example #{index + 1}: purchase_id=#{purchase.id} external_id=#{purchase.external_id}"
        Rails.logger.info "  created_at=#{purchase.created_at} price=#{purchase.price_cents}c tax=#{purchase.gumroad_tax_cents || 0}c"
        Rails.logger.info "  country=#{info&.country_code} ip=#{info&.ip_country_code} card=#{purchase.card_country.presence || info&.card_country_code}"
        Rails.logger.info "  was_purchase_taxable=#{purchase.was_purchase_taxable} zip_tax_rate_id=#{purchase.zip_tax_rate_id || 'nil'}"
        Rails.logger.info "  product_type=#{product&.is_physical ? 'Physical' : 'Digital'}"
      end
    end

    def analyze_patterns(purchases)
      Rails.logger.info "\n### PATTERN ANALYSIS (#{purchases.size} purchases) ###"

      taxable_countries = taxable_country_codes_for_location_validation

      ip_countries = Hash.new(0)
      card_countries = Hash.new(0)
      location_guard_hits = 0

      purchases.each do |purchase|
        info = purchase.purchase_sales_tax_info
        ip_countries[info&.ip_country_code || "unknown"] += 1
        card_countries[purchase.card_country.presence || info&.card_country_code || "unknown"] += 1

        if matches_location_guard_condition?(purchase, taxable_countries)
          location_guard_hits += 1
        end
      end

      Rails.logger.info "\nIP Country Distribution (top 5):"
      ip_countries.sort_by { |_, v| -v }.first(5).each { |c, n| Rails.logger.info "  #{c}: #{n}" }

      Rails.logger.info "\nCard Country Distribution (top 5):"
      card_countries.sort_by { |_, v| -v }.first(5).each { |c, n| Rails.logger.info "  #{c}: #{n}" }

      Rails.logger.info "\n### ROOT CAUSE CHECK ###"
      Rails.logger.info "Condition: selected country is taxable (IN), but IP/card are both non-taxable."
      Rails.logger.info "Matches: #{location_guard_hits} / #{purchases.size}"

      if location_guard_hits > 0
        pct = (location_guard_hits.to_f / purchases.size * 100).round(1)
        Rails.logger.info "=> #{pct}% of buggy purchases match the pre-fix bailout condition."
        Rails.logger.info "=> This confirms the fix in Purchase#tax_location_valid? addresses the root cause." if pct > 50
      end
    end

    def taxable_country_codes_for_location_validation
      taxable_countries =
        Compliance::Countries::EU_VAT_APPLICABLE_COUNTRY_CODES |
        Compliance::Countries::GST_APPLICABLE_COUNTRY_CODES |
        Compliance::Countries::OTHER_TAXABLE_COUNTRY_CODES |
        Compliance::Countries::NORWAY_VAT_APPLICABLE_COUNTRY_CODES

      Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_ALL_PRODUCTS.each do |country_code|
        taxable_countries << country_code if Feature.active?("collect_tax_#{country_code.downcase}")
      end

      Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_DIGITAL_PRODUCTS.each do |country_code|
        taxable_countries << country_code if Feature.active?("collect_tax_#{country_code.downcase}")
      end

      taxable_countries.uniq
    end

    def buggy_purchases_scope
      Purchase
        .joins(:purchase_sales_tax_info)
        .where(purchase_state: Purchase::ALL_SUCCESS_STATES)
        .where("purchases.created_at >= ?", MONTHS_TO_SEARCH.months.ago)
        .where("purchases.price_cents > 0")
        .where("purchase_sales_tax_infos.country_code = ?", INDIA_COUNTRY_CODE)
        .where("(purchases.gumroad_tax_cents = 0 OR purchases.gumroad_tax_cents IS NULL)")
        .where("(purchases.tax_cents = 0 OR purchases.tax_cents IS NULL)")
        .where("purchase_sales_tax_infos.business_vat_id IS NULL OR purchase_sales_tax_infos.business_vat_id = ''")
        .order(created_at: :desc)
    end

    def matches_location_guard_condition?(purchase, taxable_countries)
      product = purchase.link
      return false if product.nil? || product.is_physical || product.require_shipping

      info = purchase.purchase_sales_tax_info
      selected_country_code = info&.country_code
      return false if selected_country_code.blank?

      ip_country_code = info&.ip_country_code
      card_country_code = purchase.card_country.presence || info&.card_country_code
      ip_and_card_locations = [ip_country_code, card_country_code].compact

      selected_country_code.in?(taxable_countries) && (ip_and_card_locations & taxable_countries).empty?
    end
end
