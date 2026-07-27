# frozen_string_literal: true

# Computes what Gumroad owes each foreign tax authority for a calendar
# quarter, from the tax we actually collected on purchases in that quarter.
#
# Why this exists (gumroad-private#1100): the quarterly international VAT/GST
# remittances have always been sized by hand — someone runs a report, reads
# the per-country tax collected, and types the amounts into a payments
# dashboard. That number is the input every other part of the automation
# depends on, and until now it lived nowhere reviewable. This turns it into a
# service with tests, so the amount owed for a quarter can be computed (and
# re-computed, and diffed) without anyone's console history.
#
# Deliberately rail-agnostic: this only answers "how much, to whom, in what
# currency". Which payment rail carries the money (Wise, Stripe Global
# Payouts, Mercury) is a separate decision recorded on the tax_remittances
# row, so nothing here assumes access to any particular provider.
#
# Period attribution is NOT re-implemented here. It reuses the same model
# scopes CreateGlobalSalesTaxSummaryReportJob files from
# (Purchase.not_fully_refunded_for_tax_reporting,
# Refund.for_tax_period_reporting, Purchase.chargebacks_for_tax_period_reporting,
# and their cutover constants), because two implementations of "which period
# does this refund belong to" would eventually disagree and we would remit a
# different number than we filed. The one thing this does differently is
# grouping: remittances are per COUNTRY, so none of the report's US
# zip-code/state resolution applies.
#
# Amounts are USD cents throughout — gumroad_tax_cents is stored in USD. The
# local-currency amount an authority is actually paid in depends on the FX
# rate at payment time, so it is not computed here; the payment step records
# it on the row afterward.
class TaxRemittances::QuarterlyLiabilityCalculator
  # Buyer country code => the authority Gumroad remits that country's
  # collected tax to. Derived from the live compliance country lists rather
  # than hardcoded, so adding a country to EU VAT (or to the GST list) routes
  # it automatically instead of silently going unremitted.
  #
  # The EU one-stop-shop is the reason this is not a 1:1 country/authority
  # map: tax collected across all EU member states is remitted in a single
  # payment to Irish Revenue under the OSS scheme. The UK appears in
  # EU_VAT_APPLICABLE_COUNTRY_CODES for historical reasons (the constant kept
  # GB after Brexit because UK VAT is still collected at an EU-style rate),
  # but the UK is emphatically not part of the OSS return — it is filed
  # separately with HMRC, so it must be pulled out of the EU bucket here.
  # Getting this wrong would send the UK's VAT to Dublin.
  EU_OSS_AUTHORITY = "Irish Revenue (EU VAT OSS)"

  # Non-OSS authorities, each remitting a single country's collected tax.
  SINGLE_COUNTRY_AUTHORITIES = {
    Compliance::Countries::GBR.alpha2 => "HMRC",
    Compliance::Countries::AUS.alpha2 => "Australian Taxation Office",
    Compliance::Countries::NOR.alpha2 => "Norwegian Tax Administration",
    Compliance::Countries::NZL.alpha2 => "Inland Revenue Department (NZ)",
    Compliance::Countries::CHE.alpha2 => "Eidgenössisches Finanzdepartement (Swiss VAT)",
    Compliance::Countries::SGP.alpha2 => "IRAS Singapore",
  }.freeze

  # The EU member states whose collected tax is remitted through the OSS
  # return: the EU VAT list minus every country that files on its own.
  def self.eu_oss_country_codes
    Compliance::Countries::EU_VAT_APPLICABLE_COUNTRY_CODES - SINGLE_COUNTRY_AUTHORITIES.keys
  end

  # country code => authority, for every country covered by a known authority.
  def self.authority_by_country_code
    @authority_by_country_code ||= begin
      mapping = eu_oss_country_codes.index_with { EU_OSS_AUTHORITY }
      mapping.merge(SINGLE_COUNTRY_AUTHORITIES).freeze
    end
  end

  PERIOD_FORMAT = TaxRemittance::PERIOD_FORMAT

  # One authority's computed liability for the period. `tax_collected_cents`
  # is the net figure to remit; the leg breakdown is kept so a reviewer can
  # see how it was reached without re-running anything.
  Liability = Struct.new(
    :authority,
    :jurisdiction,
    :currency,
    :tax_collected_cents,
    :sales_tax_cents,
    :refunded_tax_cents,
    :chargeback_tax_cents,
    :country_codes,
    keyword_init: true
  )

  attr_reader :period, :liabilities, :unmapped_countries, :unresolved_country_names, :countryless_tax_cents

  # period — a quarter string like "2026-Q2", matching TaxRemittance#period.
  def initialize(period)
    raise ArgumentError, "period must look like 2026-Q1 (got #{period.inspect})" unless period.to_s.match?(PERIOD_FORMAT)

    @period = period
    reset_results
  end

  def process
    # Every result is recomputed from scratch, so clear the previous run's
    # too. Without this, calling process twice would keep coverage gaps that
    # no longer exist and add the same unresolved tax in again, while the
    # liabilities beside them were freshly computed — a mix a reviewer has no
    # way to spot.
    reset_results

    by_country = Hash.new { |hash, key| hash[key] = { sales: 0, refunds: 0, chargebacks: 0 } }

    accumulate_sales_leg(by_country)
    accumulate_refund_leg(by_country)
    accumulate_chargeback_legs(by_country)

    build_liabilities(by_country)
    prune_settled_diagnostics

    Rails.logger.info(
      "#{self.class.name}: period=#{period} authorities=#{liabilities.size} " \
      "total_usd_cents=#{total_usd_cents} unmapped_countries=#{unmapped_countries.size} " \
      "unresolved_country_names=#{unresolved_country_names.size} " \
      "countryless_tax_cents=#{countryless_tax_cents}"
    )

    self
  end

  def total_usd_cents
    liabilities.sum(&:tax_collected_cents)
  end

  # Countries where we collected tax in this period but that no authority in
  # this map remits. Surfacing them is the point: silently dropping a country
  # is how a filing obligation goes unnoticed. Expected entries are the
  # countries paid through other rails (US state sales tax goes to TaxJar,
  # Canada is filed separately) — anything unexpected here needs a human.
  def unmapped_country_report
    unmapped_countries.sort_by { |_code, cents| -cents }
  end

  # Quarter boundaries. Period strings are validated in the constructor, so
  # the quarter number is always 1-4 here.
  def period_range
    year, quarter = period.split("-Q")
    first_month = ((quarter.to_i - 1) * 3) + 1
    starts_at = Date.new(year.to_i, first_month, 1).beginning_of_day
    starts_at..starts_at.to_date.end_of_quarter.end_of_day
  end

  private
    # Purchases created in the quarter, filtered exactly as the global sales
    # tax summary report filters its sales leg. Amounts come from
    # gumroad_tax_cents_for_tax_reporting so pre-cutover refunds stay netted
    # into their purchase's own quarter while post-cutover refunds are
    # subtracted by the refund leg instead — never both.
    def accumulate_sales_leg(by_country)
      sales_scope
        .select(:id, :country, :ip_country, :created_at, :gumroad_tax_cents,
                :stripe_partially_refunded, :stripe_refunded, :flags, :chargeback_date)
        .find_each do |purchase|
          leg_tax_cents = purchase.gumroad_tax_cents_for_tax_reporting.to_i
          code = country_code_for(purchase, leg_tax_cents)
          next if code.blank?

          by_country[code][:sales] += leg_tax_cents
        end
    end

    def sales_scope
      Purchase.successful
        .not_fully_refunded_for_tax_reporting
        .not_chargedback_for_tax_reporting
        .where.not(stripe_transaction_id: nil)
        .where("purchases.gumroad_tax_cents > 0")
        .where(charge_processor_id: [nil, *ChargeProcessor.charge_processor_ids])
        .where(created_at: period_range)
    end

    # Refunds issued during the quarter reduce this quarter's liability,
    # bucketed by the buyer country of the ORIGINAL purchase and dated by the
    # refund's own date — a refund is a correction in the period it happens
    # in, which is how it appears on the return we file.
    def accumulate_refund_leg(by_country)
      Refund.for_tax_period_reporting(period_range.first, period_range.last)
        .joins(:purchase)
        .merge(
          Purchase.successful
            .not_chargedback_for_tax_reporting
            .where.not(purchases: { stripe_transaction_id: nil })
            .where("purchases.gumroad_tax_cents > 0")
            .where(purchases: { charge_processor_id: [nil, *ChargeProcessor.charge_processor_ids] })
        )
        .includes(:purchase)
        .find_each do |refund|
          # A refund REDUCES the tax at stake for its country, so the
          # diagnostics get a negative amount. Passing the purchase's gross
          # tax here instead would count the same sale again on every leg and
          # overstate what a reviewer is asked to chase down.
          leg_tax_cents = refund.gumroad_tax_cents.to_i
          code = country_code_for(refund.purchase, -leg_tax_cents)
          next if code.blank?

          by_country[code][:refunds] += leg_tax_cents
        end
    end

    # Chargebacks formalized in the quarter reduce it; disputes won in the
    # quarter add back. Same event-dating and same purchase filters as the
    # report's chargeback legs.
    def accumulate_chargeback_legs(by_country)
      chargeback_filters(Purchase.chargebacks_for_tax_period_reporting(period_range.first, period_range.last))
        .find_each do |purchase|
          leg_tax_cents = purchase.gumroad_tax_cents_for_chargeback_reporting.to_i
          code = country_code_for(purchase, -leg_tax_cents)
          next if code.blank?

          by_country[code][:chargebacks] += leg_tax_cents
        end

      chargeback_filters(Purchase.chargeback_reversals_for_tax_period_reporting(period_range.first, period_range.last))
        .find_each do |purchase|
          # Re-check the win date against the window: the scope finds purchases
          # with a dispute won in the period, but the leg is dated by the
          # specific dispute row that wins (see
          # Purchase#chargeback_reversal_reporting_date), which is the same
          # resolution the report applies.
          won_at = purchase.chargeback_reversal_reporting_date
          next unless won_at && period_range.cover?(won_at)

          # A won dispute adds the tax back, so it adds back here too.
          leg_tax_cents = purchase.gumroad_tax_cents_for_chargeback_reporting.to_i
          code = country_code_for(purchase, leg_tax_cents)
          next if code.blank?

          by_country[code][:chargebacks] -= leg_tax_cents
        end
    end

    def chargeback_filters(scope)
      scope
        .successful
        .where.not(stripe_transaction_id: nil)
        .where("purchases.gumroad_tax_cents > 0")
        .where(charge_processor_id: [nil, *ChargeProcessor.charge_processor_ids])
    end

    # The buyer's country as a two-letter code. `purchases.country` holds a
    # country NAME (not a code) and may be missing, in which case we fall back
    # to the GeoIP-derived ip_country — the same precedence the global sales
    # tax summary report uses, so a purchase lands in the same bucket in both.
    #
    # A name that doesn't resolve to any country is recorded in
    # unresolved_country_names rather than quietly discarded. The report can
    # afford to bucket these as "Unknown" because a human reads the CSV; here
    # the output is a payment amount, so an unresolvable name means tax we
    # collected and might not remit. ISO name matching is not exhaustive
    # (e.g. "Slovak Republic" and "Holland" both fail), so this is a real
    # possibility, not a theoretical one.
    #
    # leg_tax_cents is THIS leg's signed contribution, not the purchase's
    # gross tax: positive for a sale or a won dispute, negative for a refund
    # or a chargeback. The diagnostics below net those together so the amount
    # a reviewer is asked to chase is the tax still at stake, not the sum of
    # every leg that touched the same purchase.
    def country_code_for(purchase, leg_tax_cents)
      raw = purchase.country.presence || purchase.ip_country.presence

      # No country name and no GeoIP country. There is nowhere to file this
      # tax, which makes it the same class of problem as an unresolvable
      # name: real money we collected that no return accounts for. Returning
      # early without recording it is how it goes missing entirely — it
      # appears in neither the liabilities nor any coverage gap.
      if raw.blank?
        @countryless_tax_cents += leg_tax_cents
        return nil
      end

      code = normalized_country_codes[raw]
      @unresolved_country_names[raw] += leg_tax_cents if code.nil?
      code
    end

    def reset_results
      @liabilities = []
      @unmapped_countries = {}
      @unresolved_country_names = Hash.new(0)
      @countryless_tax_cents = 0
    end

    # Diagnostics are netted across legs, so an entry can land at zero or
    # below — tax collected in the quarter and then fully refunded in it. That
    # is settled, with nothing left to chase, so it is dropped rather than
    # reported as a gap. This mirrors how build_liabilities declines to report
    # an unmapped country that nets to nothing.
    def prune_settled_diagnostics
      @unresolved_country_names.delete_if { |_name, cents| cents <= 0 }
    end

    def normalized_country_codes
      @normalized_country_codes ||= Hash.new do |hash, raw_name|
        hash[raw_name] = Compliance::Countries.find_by_name(raw_name)&.alpha2
      end
    end

    def build_liabilities(by_country)
      per_authority = Hash.new { |hash, key| hash[key] = { sales: 0, refunds: 0, chargebacks: 0, countries: [] } }

      by_country.each do |country_code, legs|
        authority = self.class.authority_by_country_code[country_code]
        net = legs[:sales] - legs[:refunds] - legs[:chargebacks]

        if authority.nil?
          # Only report a coverage gap when there is actually money to remit.
          # A country whose collections net to zero (or negative, e.g. refunds
          # of an earlier quarter's sales) has no filing obligation to flag.
          @unmapped_countries[country_code] = net if net > 0
          next
        end

        bucket = per_authority[authority]
        bucket[:sales] += legs[:sales]
        bucket[:refunds] += legs[:refunds]
        bucket[:chargebacks] += legs[:chargebacks]
        bucket[:countries] << country_code
      end

      @liabilities = per_authority.filter_map do |authority, bucket|
        net = bucket[:sales] - bucket[:refunds] - bucket[:chargebacks]
        # Nothing owed means nothing to remit: a zero or negative net (more
        # refunded than collected this quarter) is carried on the next return
        # as an adjustment by the tax agent, not sent as a payment.
        next if net <= 0

        meta = TaxRemittance::KNOWN_AUTHORITIES.fetch(authority)

        Liability.new(
          authority:,
          jurisdiction: meta[:jurisdiction],
          currency: meta[:currency],
          tax_collected_cents: net,
          sales_tax_cents: bucket[:sales],
          refunded_tax_cents: bucket[:refunds],
          chargeback_tax_cents: bucket[:chargebacks],
          country_codes: bucket[:countries].sort,
        )
      end.sort_by { |liability| -liability.tax_collected_cents }
    end
end
