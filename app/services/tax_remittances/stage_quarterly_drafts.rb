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
#
# Safe and intended to be re-run while a quarter is still settling: a draft
# nobody has touched yet is updated to the newly computed amount, a row a human
# has already picked up is never written to, and a filing that was already paid
# is never staged again.
class TaxRemittances::StageQuarterlyDrafts
  # Rows are created in the intended rail so that a per-authority rail
  # decision is visible on the draft from the start. Wise is the default
  # because it is the rail these seven authorities are paid through today.
  DEFAULT_RAIL = "wise"

  attr_reader :period, :rail, :created, :refreshed, :skipped, :orphaned_drafts, :calculator

  def initialize(period, rail: DEFAULT_RAIL)
    raise ArgumentError, "unknown rail #{rail.inspect}" unless rail.in?(TaxRemittance::RAILS)

    # Period format is validated by the calculator, which owns that contract.
    @calculator = TaxRemittances::QuarterlyLiabilityCalculator.new(period)
    @period = period
    @rail = rail
    @created = []
    @refreshed = []
    @skipped = []
    @orphaned_drafts = []
  end

  def process
    calculator.process

    calculator.liabilities.each do |liability|
      stage(liability)
    end

    collect_orphaned_drafts

    Rails.logger.info(
      "#{self.class.name}: period=#{period} rail=#{rail} created=#{created.size} " \
      "refreshed=#{refreshed.size} skipped=#{skipped.size} orphaned_drafts=#{orphaned_drafts.size}"
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
    #
    # A still-untouched `draft` is the one case where the existing row is
    # UPDATED instead of skipped: the amount a quarter owes keeps moving while
    # the quarter is open (late sales, refunds, chargebacks), and this service
    # is meant to be re-run as that happens. Leaving the first run's number in
    # place would hand a reviewer an amount that no longer matches the sales
    # data, which is exactly the approval mistake this table exists to
    # prevent. From pending_approval onward a human is already working the
    # row, so it is left alone and the drift is reported in the skip reason
    # instead of being changed underneath them.
    def stage(liability)
      existing = TaxRemittance.where(authority: liability.authority, period:)
                              .where.not(status: TaxRemittance::RETRYABLE_STATUSES)
                              .first

      if existing
        refresh_or_skip(existing, liability)
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

    # An existing live attempt: bring an untouched draft back in line with the
    # freshly computed liability, and leave anything a human has already
    # started on alone.
    def refresh_or_skip(existing, liability)
      new_notes = draft_notes(liability)
      outcome = nil

      # The status check and the write have to be one indivisible step. Reading
      # the status off the in-memory row and then updating it is a race a human
      # can lose money to: a reviewer who submits the draft for approval in the
      # moment between our read and our write still looks like a `draft` to
      # this object, so the refresh would overwrite the amount they are in the
      # middle of approving and report it as a clean refresh. `with_lock`
      # re-reads the row with SELECT ... FOR UPDATE inside a transaction, so
      # the status decided on below is the committed one and no one else can
      # change it until this block commits. A reviewer's own transition either
      # commits first (we see it and leave the row alone) or waits for us and
      # then applies on top of a refreshed draft — never silently on top of a
      # discarded amount.
      #
      # The lock cannot tell us whether the human SAW the refreshed number,
      # only that the write order is safe. That half is enforced on the other
      # side: TaxRemittance#submit_for_approval! takes the amount the reviewer
      # was shown and refuses the transition if this refresh has moved it since.
      existing.with_lock do
        if existing.status != "draft"
          outcome = [:skip_live, stale_amount_for(existing, liability)]
        elsif existing.usd_amount_cents == liability.tax_collected_cents && existing.notes == new_notes
          outcome = [:already_matches]
        else
          previous_amount_cents = existing.usd_amount_cents
          existing.update!(usd_amount_cents: liability.tax_collected_cents, notes: new_notes)
          outcome = [:refreshed, previous_amount_cents]
        end
      end

      case outcome
      in [:skip_live, stale_amount]
        @skipped << {
          authority: liability.authority,
          reason: "live attempt #{existing.attempt} in status #{existing.status}",
          stale_amount:,
        }.compact
      in [:already_matches]
        @skipped << { authority: liability.authority, reason: "draft attempt #{existing.attempt} already matches the computed liability" }
      in [:refreshed, previous_amount_cents]
        @refreshed << {
          remittance: existing,
          authority: liability.authority,
          from_cents: previous_amount_cents,
          to_cents: liability.tax_collected_cents,
        }
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
      # Either the row was deleted under us, or a validation on it now refuses
      # the write. Report it instead of failing the whole quarter's staging.
      @skipped << { authority: liability.authority, reason: "could not refresh draft attempt #{existing.attempt} (#{e.class.name})" }
    end

    # How far a row we are NOT touching has drifted from what the quarter now
    # says is owed. Reported rather than silently tolerated: a pending_approval
    # row sized before a late refund landed is a payment about to be approved
    # for the wrong amount, and only a human can decide whether to send it,
    # cancel it, or adjust on the next return.
    def stale_amount_for(existing, liability)
      return if existing.usd_amount_cents == liability.tax_collected_cents

      { recorded_cents: existing.usd_amount_cents, computed_cents: liability.tax_collected_cents }
    end

    # Drafts for authorities the quarter no longer owes anything to. The
    # calculator drops an authority entirely once refunds and chargebacks
    # cancel out its collections, so those filings are never visited by the
    # staging loop above and their drafts would otherwise sit there proposing a
    # payment that is no longer owed. Left in place rather than deleted — a
    # draft cannot move money, and whether the right answer is cancelling it or
    # carrying an adjustment onto the next return is a filing decision.
    def collect_orphaned_drafts
      staged_authorities = calculator.liabilities.map(&:authority)

      TaxRemittance.where(period:, status: "draft")
                   .where.not(authority: staged_authorities)
                   .find_each do |remittance|
        @orphaned_drafts << {
          remittance:,
          authority: remittance.authority,
          recorded_cents: remittance.usd_amount_cents,
        }
      end
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
