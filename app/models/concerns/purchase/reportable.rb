# frozen_string_literal: true

module Purchase::Reportable
  extend ActiveSupport::Concern

  # The day tax report jobs switched refund reporting on. A refund is an event of the period it
  # happens in (matching how corrections are reported in the current return), so refunds created
  # on/after this day are reported by the tax report jobs as their own negative rows/adjustments
  # in the period of the refund — not netted into the original purchase's period.
  #
  # Refunds created before this day were handled the old way — netted into their purchase's
  # amounts at report generation time — and stay netted, so historical reports regenerate to
  # (approximately) their as-filed numbers and no refund is ever counted twice. The two legs
  # partition refunds exactly by this instant:
  #
  # - purchase created on/after the cutover: reported at gross (as-of-purchase) amounts; every
  #   one of its refunds shows up as a refund row in the refund's own period.
  # - purchase created before the cutover: reported net of only its pre-cutover refunds (the
  #   exact complement of the refunds that get refund rows).
  #
  # This is the single source of truth for the cutover instant: UsStateSalesTaxUploader (the
  # TaxJar push path) aliases this constant, so the push path and the report jobs can never
  # partition refunds at different instants. Same lineage as the VAT report fix in #5890.
  REFUND_REPORTING_CUTOVER = Date.new(2026, 7, 20)

  # The day tax report jobs switched chargeback reporting on — the chargeback sibling of
  # REFUND_REPORTING_CUTOVER above, closing out the same bug class for disputes: a chargeback
  # is an event of the period it happens in, so chargebacks whose dispute was formalized on/after
  # this day are reported as their own negative legs in the period of `purchases.chargeback_date`
  # (which has always held the payment processor's dispute-formalized event timestamp, so no
  # backfill is ever needed), while the original sale stays reported in the purchase's own period.
  # A dispute later won gets a positive re-add leg in the period of its Dispute row's `won_at`.
  #
  # Chargebacks from before this day keep the legacy attribution — the charged-back purchase is
  # dropped from (or, when the dispute was won, re-added to) its purchase period at generation
  # time — so historical reports regenerate to their as-filed numbers and no chargeback is ever
  # counted twice. The two treatments partition chargebacks exactly by this instant.
  #
  # Reversal (dispute won) legs are emitted only from a real Dispute row's `won_at` — reversal
  # dates are never synthesized. Dispute rows exist reliably for disputes from 2016 onward (see
  # the note in app/models/dispute.rb), and for every webhook-created dispute since; a reversed
  # chargeback with no locatable `won_at` (e.g. the gift/bundle child purchases that are flagged
  # without a Dispute row of their own) keeps the legacy treatment: its sale stays in the purchase
  # period and neither leg is emitted, so nothing is double-counted.
  #
  # DEPLOY DEPENDENCY: like the refund cutover, this date must be STRICTLY AFTER the day the
  # change reaches production; bump it forward if the deploy slips.
  CHARGEBACK_REPORTING_CUTOVER = Date.new(2026, 7, 27)

  class_methods do
    # Cutover instant as a time, for query bounds.
    def refund_reporting_cutover_time
      REFUND_REPORTING_CUTOVER.beginning_of_day
    end

    # Chargeback cutover instant as a time, for query bounds.
    def chargeback_reporting_cutover_time
      CHARGEBACK_REPORTING_CUTOVER.beginning_of_day
    end
  end

  def price_cents_net_of_refunds
    net_of_refunds_cents(:price_cents, :amount_cents)
  end

  def fee_cents_net_of_refunds
    net_of_refunds_cents(:fee_cents, :fee_cents)
  end

  def tax_cents_net_of_refunds
    net_of_refunds_cents(:tax_cents, :creator_tax_cents)
  end

  def gumroad_tax_cents_net_of_refunds
    net_of_refunds_cents(:gumroad_tax_cents, :gumroad_tax_cents)
  end

  def total_cents_net_of_refunds
    net_of_refunds_cents(:total_transaction_cents, :total_transaction_cents)
  end

  # Amounts for period-attributed tax reporting. Purchases created on/after the refund
  # reporting cutover return their gross (as-of-purchase) amounts — their refunds are reported
  # separately, dated by the refund's own date, so netting them here as well would relieve the
  # same tax twice. Pre-cutover purchases return their amounts net of exactly the refunds
  # created before the cutover: the precise complement of the refunds the report jobs push as
  # refund rows, which keeps regeneration of a historical period deterministic and close to its
  # as-filed numbers.
  def price_cents_for_tax_reporting
    tax_reporting_cents(:price_cents, :amount_cents)
  end

  def fee_cents_for_tax_reporting
    tax_reporting_cents(:fee_cents, :fee_cents)
  end

  def tax_cents_for_tax_reporting
    tax_reporting_cents(:tax_cents, :creator_tax_cents)
  end

  def gumroad_tax_cents_for_tax_reporting
    tax_reporting_cents(:gumroad_tax_cents, :gumroad_tax_cents)
  end

  def total_cents_for_tax_reporting
    tax_reporting_cents(:total_transaction_cents, :total_transaction_cents)
  end

  # True when this purchase's tax report amounts are its gross amounts (see above).
  def gross_amounts_for_tax_reporting?
    created_at >= self.class.refund_reporting_cutover_time
  end

  # True when this purchase's chargeback is reported by event date (a negative leg in the
  # period of chargeback_date, plus a positive leg in the period of the dispute's won_at if
  # the dispute was won) instead of the legacy drop-from-the-purchase-period treatment.
  #
  # Two conditions, matching the cutover contract on CHARGEBACK_REPORTING_CUTOVER:
  # - the chargeback event happened on/after the cutover (earlier ones stay as filed), and
  # - if the dispute was won, a real Dispute row supplies the reversal date. Without one the
  #   re-add leg could never be emitted, so the debit leg must not be either — the purchase
  #   falls back to the legacy treatment (its sale simply stays in the purchase period).
  def chargeback_event_dated_for_tax_reporting?
    return false unless chargedback?
    return false if chargeback_date < self.class.chargeback_reporting_cutover_time

    !chargeback_reversed? || chargeback_reversal_reporting_date.present?
  end

  # The instant a won dispute's reversal is reported in, taken only from a real Dispute row:
  # the purchase's own dispute rows (pre-Charge era) or the dispute on the purchase's Charge
  # (multi-purchase carts). Returns nil when no dispute row records a win — reversal dates are
  # never synthesized (see CHARGEBACK_REPORTING_CUTOVER).
  def chargeback_reversal_reporting_date
    return nil unless chargeback_reversed?

    disputes.where.not(won_at: nil).order(:won_at).last&.won_at || charge&.dispute&.won_at
  end

  # Amounts for the chargeback legs. A dispute claws back whatever part of the charge was not
  # already returned by refunds, so both the negative (chargeback) leg and the positive
  # (dispute won) leg carry the purchase's amounts net of the effective refunds that existed
  # before the chargeback — refunds are already relieved by their own reporting path (netted
  # into the sale for pre-cutover refunds, refund rows for post-cutover ones). Only refunds
  # from before the chargeback are netted because that set can never change afterwards: a
  # purchase with a live (lost) chargeback cannot be refunded at all, and a refund issued
  # after a dispute win (which the refund flow does allow) must not rewrite the debit and
  # re-add legs already filed for past periods — it is relieved by the refund leg of its own
  # period instead, and the filed legs stay exactly as generated.
  def price_cents_for_chargeback_reporting
    chargeback_reporting_cents(:price_cents, :amount_cents)
  end

  def fee_cents_for_chargeback_reporting
    chargeback_reporting_cents(:fee_cents, :fee_cents)
  end

  def tax_cents_for_chargeback_reporting
    chargeback_reporting_cents(:tax_cents, :creator_tax_cents)
  end

  def gumroad_tax_cents_for_chargeback_reporting
    chargeback_reporting_cents(:gumroad_tax_cents, :gumroad_tax_cents)
  end

  def total_cents_for_chargeback_reporting
    chargeback_reporting_cents(:total_transaction_cents, :total_transaction_cents)
  end

  private
    def net_of_refunds_cents(purchase_attribute, refund_attribute)
      # Fully refunded or Chargebacked not reversed
      return 0 if chargedback_not_reversed_or_refunded?
      # No chargeback or refunds
      return self.send(purchase_attribute) unless stripe_partially_refunded? || chargedback_not_reversed_or_refunded?
      # Effective refunds only: a failed (bounced) refund never delivered money, so
      # it must not reduce reported net revenue.
      refunded_cents = refunds.effective.sum(refund_attribute)
      # No refunded amount
      return self.send(purchase_attribute) unless refunded_cents > 0
      # Partially refunded amount
      net_cents = self.send(purchase_attribute) - refunded_cents
      return net_cents if net_cents > 0
      Rails.logger.info "Unknown #{purchase_attribute} for purchase: #{self.id}"
      # Something is wrong, we have more refunds than actual collection of fees, just ignore
      0
    end

    def tax_reporting_cents(purchase_attribute, refund_attribute)
      # A lost chargeback zeroes the sale's reported amounts ONLY under the legacy treatment
      # (pre-cutover chargebacks, or ones that can't be event-dated — see
      # chargeback_event_dated_for_tax_reporting?). An event-dated chargeback keeps the sale
      # reported in the purchase's own period; the clawback is reported as a separate negative
      # leg in the period of chargeback_date, so zeroing the sale here too would count it twice.
      return 0 if chargedback_not_reversed? && !chargeback_event_dated_for_tax_reporting?

      gross_cents = self.send(purchase_attribute)
      return gross_cents if gross_amounts_for_tax_reporting?
      # Skip the refunds query when nothing was ever refunded.
      return gross_cents unless stripe_partially_refunded? || stripe_refunded?

      # Net only effective pre-cutover refunds — Refund.effective is the canonical "money
      # actually moved" scope (keeps failed-but-not-reversed, drops reversed failures), the
      # same definition used by the post-cutover refund leg (Refund.for_tax_period_reporting)
      # and the other tax reports (VAT, global summary). Using one scope everywhere keeps a
      # single, auditable answer to "which refunds count" across the whole reporting family.
      refunded_cents = refunds.effective.where("refunds.created_at < ?", self.class.refund_reporting_cutover_time).sum(refund_attribute)
      net_cents = gross_cents - refunded_cents
      net_cents.positive? ? net_cents : 0
    end

    # Amounts for the chargeback debit leg and the dispute-won re-add leg: the purchase's
    # amounts net of the effective refunds created before the chargeback, clamped at zero.
    # This is what the dispute actually claws back — money already returned by a refund is
    # not clawed back again, and every refund is relieved by its own reporting path (netted
    # into the sale for pre-cutover refunds, refund rows for post-cutover ones), so the
    # identity "sale leg + refund legs + chargeback leg (+ won leg) = money actually kept"
    # holds regardless of which side of the refund cutover the purchase or its refunds fall.
    #
    # The time bound makes the legs immutable once generated. Refunds are blocked while a
    # chargeback stands, but become possible again after a dispute win — and a refund issued
    # then must not shrink debit/re-add legs already filed for past periods (it reports
    # through the refund leg of its own period instead). Bounding by chargeback_date pins
    # the netted set at the instant the chargeback came into existence.
    def chargeback_reporting_cents(purchase_attribute, refund_attribute)
      gross_cents = self.send(purchase_attribute)
      refunded_cents = refunds.effective.where("refunds.created_at < ?", chargeback_date).sum(refund_attribute)
      net_cents = gross_cents - refunded_cents
      net_cents.positive? ? net_cents : 0
    end
end
