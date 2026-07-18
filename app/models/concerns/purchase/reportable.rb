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

  class_methods do
    # Cutover instant as a time, for query bounds.
    def refund_reporting_cutover_time
      REFUND_REPORTING_CUTOVER.beginning_of_day
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
      # Chargebacks are still attributed by the purchase's current flags — the chargeback
      # event-date pass is tracked separately (legacy chargebacks have no dispute rows to
      # date them by), so this keeps the existing behavior for charged-back purchases.
      return 0 if chargedback_not_reversed?

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
end
