# frozen_string_literal: true

# Turns a quarter's computed tax liability into `draft` rows in
# tax_remittances — the staging step between "we know what we owe" and "a
# human approves a payment".
#
# Why this exists (gumroad-private#1100): the quarterly remittances are
# currently sized and entered by hand at filing time. Running this the day a
# quarter closes means the whole quarter's payments already exist in the
# system of record, with amounts, before anyone opens a payments dashboard —
# so the remaining human step is reviewing and approving numbers rather than
# computing and typing them.
#
# Deliberately rail-agnostic. The rail (Wise, Stripe Global Payouts, Mercury)
# is recorded per row so reconciliation is uniform, but nothing here contacts
# a payment provider or needs a provider credential; drafts are just rows. The
# rail passed in is the intended one and can still be changed on the draft
# before it is funded.
#
# Nothing is ever paid by this service. Every row is created as `draft`, which
# under the TaxRemittance lifecycle cannot move money — a human moves it to
# pending_approval and approves it.
class TaxRemittances::StageQuarterlyDrafts
  # Rows are created in the intended rail so that a per-authority rail
  # decision is visible on the draft from the start. Wise is the default
  # because it is the rail these seven authorities are paid through today.
  DEFAULT_RAIL = "wise"

  attr_reader :period, :rail, :created, :skipped, :calculator

  def initialize(period, rail: DEFAULT_RAIL)
    raise ArgumentError, "unknown rail #{rail.inspect}" unless rail.in?(TaxRemittance::RAILS)

    # Period format is validated by the calculator, which owns that contract.
    @calculator = TaxRemittances::QuarterlyLiabilityCalculator.new(period)
    @period = period
    @rail = rail
    @created = []
    @skipped = []
  end

  def process
    calculator.process

    calculator.liabilities.each do |liability|
      stage(liability)
    end

    Rails.logger.info(
      "#{self.class.name}: period=#{period} rail=#{rail} created=#{created.size} skipped=#{skipped.size}"
    )

    self
  end

  # Coverage gaps found while computing the quarter, passed through from the
  # calculator so a caller that only runs this service still sees them. Tax
  # collected against a country with no authority mapped, a country name that
  # doesn't resolve, or a purchase with no country at all all mean potential
  # unremitted tax — staging drafts without surfacing that would hide it
  # behind a tidy-looking set of rows.
  def coverage_gaps
    {
      unmapped_countries: calculator.unmapped_country_report,
      unresolved_country_names: calculator.unresolved_country_names,
      countryless_tax_cents: calculator.countryless_tax_cents,
    }
  end

  private
    # Creates one draft per authority, unless that filing already has a live
    # attempt. "Live" is any non-retryable status (draft through completed):
    # if a draft already exists we must not add a second one, and if the
    # filing was already paid we must certainly not stage a fresh payment for
    # it. The model's single-live-attempt-per-filing validation enforces this
    # too — checking here means a re-run reports a clean skip instead of
    # raising, so this service is safe to run repeatedly as a quarter closes.
    def stage(liability)
      existing = TaxRemittance.where(authority: liability.authority, period:)
                              .where.not(status: TaxRemittance::RETRYABLE_STATUSES)
                              .first

      if existing
        @skipped << { authority: liability.authority, reason: "live attempt #{existing.attempt} in status #{existing.status}" }
        return
      end

      # A previous attempt may have failed or been cancelled; the next attempt
      # continues the filing's numbering rather than restarting at 1, so the
      # history stays append-only and the unique (authority, period, attempt)
      # index is respected.
      next_attempt = (TaxRemittance.where(authority: liability.authority, period:).maximum(:attempt) || 0) + 1

      remittance = TaxRemittance.create!(
        authority: liability.authority,
        jurisdiction: liability.jurisdiction,
        period:,
        currency: liability.currency,
        usd_amount_cents: liability.tax_collected_cents,
        rail:,
        attempt: next_attempt,
        status: "draft",
        notes: draft_notes(liability),
      )

      @created << remittance
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      # A concurrent run (or a human staging by hand) won the race for this
      # filing. The unique index and the single-live-attempt validation make
      # that harmless — the other row exists and is the one to use — so report
      # it as a skip rather than failing the whole quarter's staging.
      @skipped << { authority: liability.authority, reason: "raced by a concurrent write (#{e.class.name})" }
    end

    # Records how the amount was derived, so a reviewer approving the payment
    # can see the legs without re-running the calculator. Amounts are USD; the
    # local-currency amount depends on the FX rate at payment time and is
    # filled in after the payment is made.
    def draft_notes(liability)
      "Staged from collected tax for #{period}. " \
      "Sales #{usd(liability.sales_tax_cents)}, " \
      "refunds -#{usd(liability.refunded_tax_cents)}, " \
      "chargebacks -#{usd(liability.chargeback_tax_cents)}, " \
      "net #{usd(liability.tax_collected_cents)}. " \
      "Countries: #{liability.country_codes.join(', ')}. " \
      "Amount is USD; local-currency amount and transfer ID recorded after payment."
    end

    def usd(cents)
      "$#{'%.2f' % (cents / 100.0)}"
    end
end
