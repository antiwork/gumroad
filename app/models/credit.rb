# frozen_string_literal: true

class Credit < ApplicationRecord
  include CurrencyHelper, JsonData

  belongs_to :user, optional: true
  belongs_to :merchant_account, optional: true
  belongs_to :crediting_user, class_name: "User", optional: true
  belongs_to :balance, optional: true
  belongs_to :chargebacked_purchase, class_name: "Purchase", optional: true
  belongs_to :dispute, optional: true
  belongs_to :returned_payment, class_name: "Payment", optional: true
  belongs_to :refund, optional: true
  belongs_to :financing_paydown_purchase, class_name: "Purchase", optional: true
  belongs_to :fee_retention_refund, class_name: "Refund", optional: true
  # Set on a credit that gives back a previously retained refund fee because the refund
  # itself later FAILED (the buyer's bank returned an async bank-transfer refund after
  # Stripe had accepted it). Distinguishes these give-backs from the original retention
  # debits — payout exports and finance reports must not present them as new refund
  # debits or unexplained credits. Such a credit carries BOTH associations: the
  # fee_retention_refund it pairs with and this marker of why it exists.
  belongs_to :failed_refund, class_name: "Refund", optional: true
  belongs_to :backtax_agreement, optional: true

  has_one :balance_transaction

  after_create :add_comment

  validates :user, :merchant_account, presence: true

  validate :validate_associated_entity

  attr_json_data_accessor :stripe_loan_paydown_id

  scope :failed_refund_fee_reversals, -> { where.not(failed_refund_id: nil) }

  def self.create_for_credit!(user:, amount_cents:, crediting_user:, reason: nil)
    credit = new
    credit.user = user
    credit.merchant_account = MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
    credit.amount_cents = amount_cents
    credit.crediting_user = crediting_user
    credit.reason = reason
    credit.save!

    balance_transaction_amount = BalanceTransaction::Amount.new(
      currency: Currency::USD,
      gross_cents: credit.amount_cents,
      net_cents: credit.amount_cents
    )
    balance_transaction = BalanceTransaction.create!(
      user: credit.user,
      merchant_account: credit.merchant_account,
      credit:,
      issued_amount: balance_transaction_amount,
      holding_amount: balance_transaction_amount
    )

    credit.balance = balance_transaction.balance
    credit.save!
    credit
  end

  def self.create_for_dispute_won!(user:, merchant_account:, dispute:, chargedback_purchase:, balance_transaction_issued_amount:, balance_transaction_holding_amount:)
    credit = new
    credit.user = user
    credit.merchant_account = merchant_account
    credit.amount_cents = balance_transaction_issued_amount.net_cents
    credit.chargebacked_purchase = chargedback_purchase
    credit.dispute = dispute
    credit.save!

    balance_transaction = BalanceTransaction.create!(
      user: credit.user,
      merchant_account: credit.merchant_account,
      credit:,
      issued_amount: balance_transaction_issued_amount,
      holding_amount: balance_transaction_holding_amount
    )

    credit.balance = balance_transaction.balance
    credit.save!
    credit
  end

  def self.create_for_returned_payment_difference!(user:, merchant_account:, returned_payment:, difference_amount_cents:)
    credit = new
    credit.user = user
    credit.merchant_account = merchant_account
    credit.amount_cents = 0
    credit.returned_payment = returned_payment
    credit.save!

    balance_transaction_issued_amount = BalanceTransaction::Amount.new(
      currency: Currency::USD,
      gross_cents: 0,
      net_cents: 0
    )
    balance_transaction_holding_amount = BalanceTransaction::Amount.new(
      currency: returned_payment.currency,
      gross_cents: difference_amount_cents,
      net_cents: difference_amount_cents
    )
    balance_transaction = BalanceTransaction.create!(
      user: credit.user,
      merchant_account: credit.merchant_account,
      credit:,
      issued_amount: balance_transaction_issued_amount,
      holding_amount: balance_transaction_holding_amount
    )

    credit.balance = balance_transaction.balance
    credit.save!
    credit
  end

  def self.create_for_vat_refund!(refund:)
    total_refunded_vat_amount = refund.total_transaction_cents
    purchase_amount = refund.purchase.total_transaction_cents
    gumroad_amount = refund.purchase.total_transaction_amount_for_gumroad_cents
    refunded_gumroad_amount = gumroad_amount * (total_refunded_vat_amount.to_f / purchase_amount)
    credit_amount = total_refunded_vat_amount - refunded_gumroad_amount.to_i

    credit = new
    credit.user = refund.purchase.seller
    credit.merchant_account = refund.purchase.stripe_charge_processor? ?
                                  MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) :
                                  MerchantAccount.gumroad(BraintreeChargeProcessor.charge_processor_id)
    credit.amount_cents = credit_amount
    credit.refund = refund
    credit.save!

    balance_transaction_amount = BalanceTransaction::Amount.new(
      currency: Currency::USD,
      gross_cents: credit.amount_cents,
      net_cents: credit.amount_cents
    )
    balance_transaction = BalanceTransaction.create!(
      user: credit.user,
      merchant_account: credit.merchant_account,
      credit:,
      issued_amount: balance_transaction_amount,
      holding_amount: balance_transaction_amount
    )

    credit.balance = balance_transaction.balance
    credit.save!
    credit
  end

  # When we refund VAT for a purchase paid via PayPal Native, we create a positive credit for the creator
  # (`Credit.create_for_vat_refund!`) to compensate for the portion of the VAT that was refunded
  # from their PayPal/Stripe Connect balance (since there's no way to specify that the refund should be taken out entirely
  # from the Gumroad's portion of the purchase, see https://github.com/gumroad/web/issues/20820#issuecomment-1021042784).
  #
  # When a purchase with VAT refund is further partially or fully refunded, we need to apply proportional negative credit
  # to the creator's balance because these refunds will be partially taken out from the Gumroad's portion
  # (for which we have already given the creator credit during the VAT refund).
  #
  # If during VAT refund we apply $X credit for the user, and afterwards the purchase is fully refunded, we should apply -$X
  # credit to even things out.
  def self.create_for_vat_exclusive_refund!(refund:)
    # Only create negative credit if:
    # - VAT was charged initially
    # - the refund does not include any VAT (meaning that VAT was refunded separately from the body of the purchase
    #   and there's no more VAT to refund left)
    return if refund.gumroad_tax_cents > 0 || refund.purchase.gumroad_tax_cents == 0

    total_refunded_amount = refund.total_transaction_cents

    purchase_gumroad_amount = refund.purchase.total_transaction_amount_for_gumroad_cents
    purchase_gumroad_tax_amount = refund.purchase.gumroad_tax_cents
    purchase_gumroad_amount_sans_vat = purchase_gumroad_amount - purchase_gumroad_tax_amount

    purchase_total_amount = refund.purchase.total_transaction_cents
    purchase_amount_sans_vat = refund.purchase.price_cents

    refunded_gumroad_amount = purchase_gumroad_amount * (total_refunded_amount.to_f / purchase_total_amount)
    expected_refunded_gumroad_amount = purchase_gumroad_amount_sans_vat * (total_refunded_amount.to_f / purchase_amount_sans_vat)

    # Negative credit amount
    amount_to_credit = (expected_refunded_gumroad_amount - refunded_gumroad_amount).round

    credit = new
    credit.user = refund.purchase.seller
    credit.merchant_account = refund.purchase.stripe_charge_processor? ?
                                  MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) :
                                  MerchantAccount.gumroad(BraintreeChargeProcessor.charge_processor_id)
    credit.amount_cents = amount_to_credit
    credit.refund = refund
    credit.save!

    balance_transaction_amount = BalanceTransaction::Amount.new(
      currency: Currency::USD,
      gross_cents: credit.amount_cents,
      net_cents: credit.amount_cents
    )
    balance_transaction = BalanceTransaction.create!(
      user: credit.user,
      merchant_account: credit.merchant_account,
      credit:,
      issued_amount: balance_transaction_amount,
      holding_amount: balance_transaction_amount
    )

    credit.balance = balance_transaction.balance
    credit.save!
    credit
  end

  def self.create_for_financing_paydown!(purchase:, amount_cents:, merchant_account:, stripe_loan_paydown_id:)
    return unless stripe_loan_paydown_id.present?

    user = merchant_account.user
    return if user.credits.where("json_data->'$.stripe_loan_paydown_id' = ?", stripe_loan_paydown_id).exists?

    credit = new
    credit.user = user
    credit.amount_cents = amount_cents
    credit.merchant_account = merchant_account
    credit.financing_paydown_purchase = purchase
    credit.stripe_loan_paydown_id = stripe_loan_paydown_id
    credit.save!

    balance_transaction_amount = BalanceTransaction::Amount.new(
      currency: Currency::USD,
      gross_cents: credit.get_usd_cents(credit.merchant_account.currency, credit.amount_cents),
      net_cents: credit.get_usd_cents(credit.merchant_account.currency, credit.amount_cents)
    )

    balance_transaction_holding_amount = BalanceTransaction::Amount.new(
      currency: credit.merchant_account.currency,
      gross_cents: credit.amount_cents,
      net_cents: credit.amount_cents
    )

    balance_transaction = BalanceTransaction.create!(
      user: credit.user,
      merchant_account: credit.merchant_account,
      credit:,
      issued_amount: balance_transaction_amount,
      holding_amount: balance_transaction_holding_amount
    )

    credit.balance = balance_transaction.balance
    credit.save!
    credit
  end

  def self.create_for_bank_debit_on_stripe_account!(amount_cents:, merchant_account:)
    create_for_balance_change_on_stripe_account!(amount_cents_holding_currency: amount_cents, merchant_account:)
  end

  def self.create_for_manual_paydown_on_stripe_loan!(amount_cents:, merchant_account:, stripe_loan_paydown_id:)
    credit = create_for_balance_change_on_stripe_account!(amount_cents_holding_currency: amount_cents, merchant_account:)
    credit.update!(stripe_loan_paydown_id:)
    credit
  end

  def self.create_for_balance_change_on_stripe_account!(amount_cents_holding_currency:, merchant_account:, amount_cents_usd: nil)
    credit = new
    credit.user = merchant_account.user
    credit_amount_cents_usd = amount_cents_usd.presence || credit.get_usd_cents(merchant_account.currency, amount_cents_holding_currency)
    credit.amount_cents = credit_amount_cents_usd
    credit.merchant_account = merchant_account
    credit.crediting_user = User.find(GUMROAD_ADMIN_ID)
    credit.save!

    balance_transaction_amount = BalanceTransaction::Amount.new(
      currency: Currency::USD,
      gross_cents: credit_amount_cents_usd,
      net_cents: credit_amount_cents_usd
    )

    balance_transaction_holding_amount = BalanceTransaction::Amount.new(
      currency: credit.merchant_account.currency,
      gross_cents: amount_cents_holding_currency,
      net_cents: amount_cents_holding_currency
    )

    balance_transaction = BalanceTransaction.create!(
      user: credit.user,
      merchant_account: credit.merchant_account,
      credit:,
      issued_amount: balance_transaction_amount,
      holding_amount: balance_transaction_holding_amount
    )

    credit.balance = balance_transaction.balance
    credit.save!
    credit
  end

  # Idempotent: runs after the refund has committed (the processor has already returned the
  # buyer's money), so it must be safe to call again when an earlier attempt failed part way.
  # The ledger rows are booked in one transaction, so an existing retention credit means the
  # only thing that can still be outstanding is the Stripe debit.
  def self.create_for_refund_fee_retention!(refund:)
    purchase = refund.purchase
    # Same purchase → refund lock order as HandleFailedRefundService / the Purchase wrapper.
    # Refuse to retain (or re-retain) a fee after the refund's balance was reversed on failure.
    # reload before lock!: callers may have read a json_data accessor on a NULL column,
    # which dirties the in-memory record and makes lock! raise.
    purchase.with_lock do
      refund.reload.lock!
      return if refund.balance_reversed_on_failure

      # Scope by user_id so MySQL can use index_credits_on_user_id_and_created_at_and_id
      # (there is no index on fee_retention_refund_id alone). Lock the row so concurrent
      # retries serialize on the same retention credit.
      existing_credit = where(user_id: purchase.seller_id, fee_retention_refund: refund, failed_refund_id: nil).lock.first
      if existing_credit.present?
        # Pre-patch US retention completed Stripe transfers without recording
        # debited_stripe_transfer. Blank marker + ledger means legacy-complete — do not
        # re-debit. New failures record FEE_DEBIT_PENDING_RETRY so retries still run.
        us_legacy_complete = existing_credit.merchant_account&.country == Compliance::Countries::USA.alpha2 &&
          refund.debited_stripe_transfer.blank? &&
          existing_credit.balance_id.present?
        unless us_legacy_complete
          actual_holding = debit_stripe_account_for_retained_fee(existing_credit)
          # Debit helper returns nil once the success marker is set; still reconcile from the
          # persisted actual when a prior attempt booked only the FX estimate.
          actual_holding ||= refund.refund_fee_holding_debit_cents
          reconcile_fee_retention_holding_amount!(existing_credit, actual_holding)
        end
        return existing_credit
      end
    end

    # We retain the payment processor fee (2.9% + 30c) and the Gumroad fee (10% + any discover fee) in case of refunds.
    # For Stripe Connect sales, the application fee includes the Gumroad fee, the VAT/sales tax,
    # and the affiliate credit. We debit connected accounts for the full application fee, so we add a positive credit
    # to the seller's balance. We have to do it this way because we don't have the seller's balance in our control,
    # so adding a negative credit to their account for Gumroad's fee wouldn't work because there likely wouldn't be a
    # balance to collect from.
    unless refund.purchase.charged_using_gumroad_merchant_account?
      purchase = refund.purchase
      application_fee_refundable_portion = purchase.gumroad_tax_cents + purchase.affiliate_credit_cents
      return if application_fee_refundable_portion.zero?

      credit = new
      credit.user = purchase.seller
      credit.amount_cents = (application_fee_refundable_portion * (refund.amount_cents.to_f / purchase.price_cents)).round
      credit.merchant_account = MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
      credit.fee_retention_refund = refund

      # requires_new: callers (Charge#refund_and_save!, processor webhook with_lock) may
      # still hold an open transaction. A nested join would let an outer rescue commit a
      # half-written credit if balance creation failed after credit.save!.
      transaction(requires_new: true) do
        credit.save!

        balance_transaction_amount = BalanceTransaction::Amount.new(
          currency: Currency::USD,
          gross_cents: credit.amount_cents,
          net_cents: credit.amount_cents
        )
        balance_transaction = BalanceTransaction.create!(
          user: credit.user,
          merchant_account: credit.merchant_account,
          credit:,
          issued_amount: balance_transaction_amount,
          holding_amount: balance_transaction_amount
        )

        credit.balance = balance_transaction.balance
        credit.save!
      end

      return credit
    end

    credit = new
    credit.user = refund.purchase.seller
    # If purchase.processor_fee_cents is present (most cases), we use it to calculate the fee to be retained.
    # We also check that purchase.processor_fee_cents_currency is 'usd' here, although that should always be the case,
    # as we are only doing this calculation for sales via gumroad-controlled Stripe accounts and Braintree,
    # and in both those cases transactions are always in USD.
    # If purchase.processor_fee_cents is not present for some reason (rare case), we calculate the fee amount,
    # that is to be retained, using the fee percentage used in Purchase#calculate_fees.
    credit.amount_cents = if refund.purchase.processor_fee_cents.present? && refund.purchase.processor_fee_cents_currency == "usd"
      -(refund.purchase.processor_fee_cents * (refund.amount_cents.to_f / refund.purchase.price_cents)).round
    else
      -(refund.amount_cents * Purchase::PROCESSOR_FEE_PER_THOUSAND / 1000.0 + (Purchase::PROCESSOR_FIXED_FEE_CENTS * refund.amount_cents.to_f / refund.purchase.price_cents)).round
    end
    credit.merchant_account = refund.purchase.merchant_account
    credit.fee_retention_refund = refund

    reversed_amount_cents_in_usd = credit.amount_cents
    reversed_amount_cents_in_holding_currency = credit.usd_cents_to_currency(credit.merchant_account.currency, credit.amount_cents)

    # Debit Stripe before booking the ledger rows: the debit records its transfer id on the
    # refund the moment it succeeds, so a retry after a failed ledger write skips Stripe
    # instead of debiting the account twice.
    net_amount_on_stripe_in_holding_currency = debit_stripe_account_for_retained_fee(credit)
    if refund.refund_fee_holding_debit_cents.present?
      holding_abs = convert_fee_holding_cents(
        refund.refund_fee_holding_debit_cents,
        from_currency: refund.refund_fee_holding_debit_currency.presence || credit.merchant_account.currency,
        to_currency: credit.merchant_account.currency
      )
      reversed_amount_cents_in_holding_currency = -holding_abs if holding_abs.present?
    elsif net_amount_on_stripe_in_holding_currency.present?
      reversed_amount_cents_in_holding_currency = -net_amount_on_stripe_in_holding_currency
    end

    # Re-take locks after Stripe: a failed-refund reversal or concurrent retention may have
    # landed while the debit ran without holding the rows.
    purchase.with_lock do
      refund.reload.lock!
      return if refund.balance_reversed_on_failure
      existing_credit = where(user_id: purchase.seller_id, fee_retention_refund: refund, failed_refund_id: nil).lock.first
      return existing_credit if existing_credit.present?

      # requires_new: see Connect branch above — isolate ledger writes from any outer txn.
      transaction(requires_new: true) do
        credit.save!

        refund.retained_fee_cents = credit.amount_cents.abs
        refund.save!

        balance_transaction_amount = BalanceTransaction::Amount.new(
          currency: Currency::USD,
          gross_cents: reversed_amount_cents_in_usd,
          net_cents: reversed_amount_cents_in_usd
        )

        balance_transaction_holding_amount = BalanceTransaction::Amount.new(
          currency: credit.merchant_account.currency,
          gross_cents: reversed_amount_cents_in_holding_currency,
          net_cents: reversed_amount_cents_in_holding_currency
        )

        balance_transaction = BalanceTransaction.create!(
          user: credit.user,
          merchant_account: credit.merchant_account,
          credit:,
          issued_amount: balance_transaction_amount,
          holding_amount: balance_transaction_holding_amount
        )

        credit.balance = balance_transaction.balance
        credit.save!
      end
    end
    credit
  end

  # Sentinel written when a Stripe fee debit fails after we already intend to book the
  # local ledger. Distinguishes a retryable new failure from a pre-patch US retention
  # that completed without recording debited_stripe_transfer.
  FEE_DEBIT_PENDING_RETRY = "pending_retry"

  # For Stripe sales that use a gumroad-managed custom connect account, pull the retained fee
  # out of that Stripe account. Best effort: the ledger is booked whether or not this
  # succeeds, a failure is reported and left for a retry, and the transfer id recorded on
  # the refund makes a second call a no-op. Returns the amount taken from the Stripe balance
  # in the account's currency, or nil when the ledger has to fall back to the converted fee.
  def self.debit_stripe_account_for_retained_fee(credit)
    merchant_account = credit.merchant_account
    refund = credit.fee_retention_refund
    return unless merchant_account.holder_of_funds == HolderOfFunds::STRIPE
    if refund.debited_stripe_transfer.present? && !fee_debit_pending_retry?(refund)
      return refund.refund_fee_holding_debit_cents.presence&.to_i ||
        StripeChargeProcessor.finish_holding_lookup_for_recorded_fee_debit(
          credit:,
          refund:,
          stripe_account_id: merchant_account.charge_processor_merchant_id
        )
    end

    if merchant_account.country == Compliance::Countries::USA.alpha2
      # For gumroad-controlled Stripe accounts from the US, we can make new debit transfers.
      # So we transfer the retained fee back to Gumroad's Stripe platform account.
      if fee_debit_submitted_without_success_marker?(refund) && fee_debit_idempotency_window_expired?(refund)
        refuse_expired_fee_debit_resubmit!(refund, StripeChargeProcessor::FEE_DEBIT_OP_US_DEBIT)
        return refund.refund_fee_holding_debit_cents.presence&.to_i
      end
      persist_refund_fee_debit_choice!(refund, operation: StripeChargeProcessor::FEE_DEBIT_OP_US_DEBIT,
                                              amount_cents: credit.amount_cents.abs)
      transfer_options = { stripe_account: merchant_account.charge_processor_merchant_id }
      transfer_options[:idempotency_key] = "refund_fee_us_debit_#{refund.external_id}" if refund.id.present?
      transfer = Stripe::Transfer.create({ amount: credit.amount_cents.abs, currency: "usd", destination: Stripe::Account.retrieve.id, },
                                         transfer_options)
      record_fee_debit_marker!(refund, transfer.id)
      persist_refund_fee_holding_on_credit!(refund, credit.amount_cents.abs, currency: Currency::USD)
      credit.amount_cents.abs
    else
      # For non-US gumroad-controlled Stripe accounts, we cannot make debit transfers.
      # So we try and reverse the retained fee amount from one of the old transfers made to that Stripe account.
      StripeChargeProcessor.debit_stripe_account_for_refund_fee(credit:)
    end
  rescue StandardError => e
    # Persist a retryable sentinel so US failures are not mistaken for legacy-complete
    # blank-marker retentions on the next attempt.
    record_fee_debit_marker!(refund, FEE_DEBIT_PENDING_RETRY) if refund.present? && refund.debited_stripe_transfer.blank?
    Rails.logger.error("Failed to debit Stripe account for the retained fee of refund #{refund.id}: #{e.class}: #{e.message}")
    ErrorNotifier.notify(e, context: { refund_id: refund.id, purchase_id: refund.purchase_id, merchant_account_id: merchant_account.id })
    nil
  end
  private_class_method :debit_stripe_account_for_retained_fee

  def self.fee_debit_pending_retry?(refund)
    refund.debited_stripe_transfer == FEE_DEBIT_PENDING_RETRY
  end
  private_class_method :fee_debit_pending_retry?

  # Write the debit marker in a requires_new savepoint. Callers that wrap retention in an
  # enclosing transaction must commit that transaction even when later ledger work fails
  # (see Purchase#debit_processor_fee_from_merchant_account!), otherwise the savepoint is
  # rolled back and a retry can debit Stripe again after the idempotency window.
  def self.record_fee_debit_marker!(refund, marker)
    transaction(requires_new: true) do
      refund.update!(debited_stripe_transfer: marker)
    end
  end
  private_class_method :record_fee_debit_marker!

  def self.persist_refund_fee_holding_on_credit!(refund, holding_debit_cents, currency: nil)
    return if refund.blank? || holding_debit_cents.blank?
    currency = currency.to_s.downcase.presence
    return if refund.refund_fee_holding_debit_cents.to_i == holding_debit_cents.to_i &&
      (currency.blank? || refund.refund_fee_holding_debit_currency.to_s.casecmp?(currency))

    transaction(requires_new: true) do
      attrs = { refund_fee_holding_debit_cents: holding_debit_cents.to_i }
      attrs[:refund_fee_holding_debit_currency] = currency if currency.present?
      refund.update!(attrs)
    end
  end
  private_class_method :persist_refund_fee_holding_on_credit!

  # Persist the chosen Stripe recovery route before submit so a timed-out response cannot
  # be retried as a different operation (e.g. transfer reversal → EUR debit).
  # Stripe documents a 24-hour idempotency key retention window. Refuse automatic
  # resubmits after this slightly shorter window so a timed-out fee debit cannot be
  # posted twice once Stripe has forgotten the original key.
  FEE_DEBIT_IDEMPOTENCY_WINDOW = 23.hours

  def self.persist_refund_fee_debit_choice!(refund, operation:, transfer_id: nil, amount_cents: nil)
    return if refund.blank?
    already = refund.refund_fee_debit_operation == operation &&
      (transfer_id.blank? || refund.refund_fee_debit_transfer_id == transfer_id) &&
      (amount_cents.blank? || refund.refund_fee_debit_amount_cents.to_i == amount_cents.to_i)
    return if already && refund.refund_fee_debit_submitted_at.present?

    transaction(requires_new: true) do
      refund.refund_fee_debit_operation = operation
      refund.refund_fee_debit_transfer_id = transfer_id if transfer_id.present?
      refund.refund_fee_debit_amount_cents = amount_cents if amount_cents.present?
      refund.refund_fee_debit_submitted_at ||= Time.current.utc.iso8601
      refund.save!
    end
  end

  # When the first Stripe attempt fails, the ledger books an estimated holding amount. A
  # later successful retry returns the actual Stripe debit; adjust the unpaid balance's
  # holding total so payout math matches Stripe. The immutable BalanceTransaction row keeps
  # its original estimate; refund_fee_holding_debit_cents records the actual.
  def self.reconcile_fee_retention_holding_amount!(credit, actual_holding_abs_cents)
    return if credit.blank? || actual_holding_abs_cents.blank?

    actual = actual_holding_abs_cents.to_i.abs
    refund = credit.fee_retention_refund
    bt = credit.balance_transaction
    return if bt.blank?

    actual_currency = (refund&.refund_fee_holding_debit_currency.presence || credit.merchant_account.currency).to_s.downcase
    actual_in_bt_currency = convert_fee_holding_cents(
      actual,
      from_currency: actual_currency,
      to_currency: bt.holding_amount_currency.to_s.downcase
    )
    return if actual_in_bt_currency.blank?

    apply_fee_retention_holding_reconcile!(
      credit:,
      refund:,
      bt:,
      actual:,
      actual_currency:,
      actual_in_bt_currency:
    )
  end
  private_class_method :reconcile_fee_retention_holding_amount!

  def self.apply_fee_retention_holding_reconcile!(credit:, refund:, bt:, actual:, actual_currency:, actual_in_bt_currency:)
    # Serialize marker read/write with the balance correction so concurrent retries cannot
    # both apply the same delta after both observing an unreconciled refund.
    lock_refund = ->(&block) do
      if refund.present?
        refund.with_lock do
          refund.reload
          # Isolate from an enclosing retention transaction so a later marker failure
          # cannot commit the balance delta without its reconciliation marker.
          transaction(requires_new: true) { block.call }
        end
      else
        transaction(requires_new: true) { block.call }
      end
    end

    lock_refund.call do
      return if refund&.refund_fee_holding_reconciled_cents.to_i == actual_in_bt_currency

      target = -actual_in_bt_currency
      previously_reconciled = refund&.refund_fee_holding_reconciled_cents
      delta = if previously_reconciled.present?
        (-actual_in_bt_currency) - (-previously_reconciled.to_i)
      else
        target - bt.holding_amount_net_cents
      end

      if delta.zero?
        refund.update!(
          refund_fee_holding_debit_cents: actual,
          refund_fee_holding_debit_currency: actual_currency,
          refund_fee_holding_reconciled_cents: actual_in_bt_currency
        ) if refund.present?
        next
      end

      balance = credit.balance || bt.balance
      return if balance.blank?

      begin
        balance.with_lock do
          balance.increment(:holding_amount_cents, delta)
          balance.save!
        end
      rescue ActiveRecord::RecordInvalid
        holding_currency = credit.merchant_account.currency.to_s.downcase
        adjusted_delta = convert_fee_holding_cents(
          delta,
          from_currency: bt.holding_amount_currency,
          to_currency: holding_currency
        )
        adjusted_delta = delta if adjusted_delta.blank?

        unpaid = Balance.where(
          user: credit.user,
          merchant_account: credit.merchant_account,
          currency: bt.issued_amount_currency,
          holding_currency:,
          state: "unpaid"
        ).order(date: :asc).first
        unpaid ||= Balance.create!(
          user: credit.user,
          merchant_account: credit.merchant_account,
          currency: bt.issued_amount_currency,
          holding_currency:,
          date: credit.created_at.to_date,
          amount_cents: 0,
          holding_amount_cents: 0
        )

        unpaid.with_lock do
          unpaid.increment(:holding_amount_cents, adjusted_delta)
          unpaid.save!
        end
      end

      refund.update!(
        refund_fee_holding_debit_cents: actual,
        refund_fee_holding_debit_currency: actual_currency,
        refund_fee_holding_reconciled_cents: actual_in_bt_currency
      ) if refund.present?
    end
  end
  private_class_method :apply_fee_retention_holding_reconcile!

  # Convert a fee debit's holding amount into another currency. BGN↔EUR uses Stripe's fixed
  # rate; other pairs go through CurrencyHelper so zero-decimal currencies stay correct.
  def self.convert_fee_holding_cents(amount_cents, from_currency:, to_currency:)
    from_currency = from_currency.to_s.downcase
    to_currency = to_currency.to_s.downcase
    return amount_cents.to_i if from_currency == to_currency

    amount = amount_cents.to_i
    bgn = StripeChargeProcessor::BGN
    if [from_currency, to_currency].sort == [bgn, Currency::EUR].sort
      return from_currency == Currency::EUR ? (BigDecimal(amount) * StripeChargeProcessor::BGN_PER_EUR).round : (BigDecimal(amount) / StripeChargeProcessor::BGN_PER_EUR).round
    end

    usd = StripeChargeProcessor.get_usd_cents(from_currency, amount)
    StripeChargeProcessor.usd_cents_to_currency(to_currency, usd)
  end
  private_class_method :convert_fee_holding_cents

  def self.fee_debit_idempotency_window_expired?(refund)
    raw = refund&.refund_fee_debit_submitted_at
    return false if raw.blank?

    submitted_at = Time.zone.parse(raw.to_s)
    submitted_at.present? && submitted_at < FEE_DEBIT_IDEMPOTENCY_WINDOW.ago
  rescue ArgumentError, TypeError
    false
  end

  # Sticky choice was written (and usually submitted) but no durable success transfer id yet.
  # pending_retry is one such state; a crash before the rescue leaves a blank marker too.
  def self.fee_debit_submitted_without_success_marker?(refund)
    return false if refund.blank?
    return false if refund.refund_fee_debit_operation.blank?
    return false if refund.debited_stripe_transfer.present? && !fee_debit_pending_retry?(refund)

    true
  end
  private_class_method :fee_debit_submitted_without_success_marker?

  def self.refuse_expired_fee_debit_resubmit!(refund, operation)
    Rails.logger.error("Refusing automatic fee debit resubmit for refund #{refund.id}: Stripe idempotency window elapsed")
    ErrorNotifier.notify(
      "Refund fee debit outside Stripe idempotency window",
      context: {
        refund_id: refund.id,
        purchase_id: refund.purchase_id,
        operation:,
        submitted_at: refund.refund_fee_debit_submitted_at,
        debited_stripe_transfer: refund.debited_stripe_transfer
      }
    )
  end
  private_class_method :refuse_expired_fee_debit_resubmit!

  # Give back the fee that create_for_refund_fee_retention! retained, because the
  # refund it was retained for later FAILED (async bank-transfer refunds can be
  # returned by the buyer's bank after Stripe accepted them). Only used on the
  # auto-reversal path, which is restricted to Gumroad-held funds — so unlike the
  # retention above there is never a Stripe transfer to unwind here; the retention
  # for Gumroad-held funds was a pure ledger debit.
  #
  # The give-back links to the same fee_retention_refund as the original retention (so
  # payout exports can pair the two rows) and sets failed_refund to record why it
  # exists, so consumers can tell the give-back from the original retention without
  # relying on its sign.
  def self.create_for_failed_refund_fee_reversal!(refund:, retention_credit:)
    credit = new
    credit.user = retention_credit.user
    credit.amount_cents = -retention_credit.amount_cents
    credit.merchant_account = retention_credit.merchant_account
    credit.fee_retention_refund = refund
    credit.failed_refund = refund
    credit.save!

    balance_transaction_amount = BalanceTransaction::Amount.new(
      currency: Currency::USD,
      gross_cents: credit.amount_cents,
      net_cents: credit.amount_cents
    )
    balance_transaction = BalanceTransaction.create!(
      user: credit.user,
      merchant_account: credit.merchant_account,
      credit:,
      issued_amount: balance_transaction_amount,
      holding_amount: balance_transaction_amount
    )

    credit.balance = balance_transaction.balance
    credit.save!
    credit
  end

  def self.create_for_partial_refund_transfer_reversal!(amount_cents_usd:, amount_cents_holding_currency:, merchant_account:)
    credit = new
    credit.user = merchant_account.user
    credit.amount_cents = amount_cents_usd
    credit.merchant_account = merchant_account
    credit.crediting_user = User.find(GUMROAD_ADMIN_ID)
    credit.save!

    balance_transaction_amount = BalanceTransaction::Amount.new(
      currency: Currency::USD,
      gross_cents: amount_cents_usd,
      net_cents: amount_cents_usd
    )

    balance_transaction_holding_amount = BalanceTransaction::Amount.new(
      currency: credit.merchant_account.currency,
      gross_cents: amount_cents_holding_currency,
      net_cents: amount_cents_holding_currency
    )

    balance_transaction = BalanceTransaction.create!(
      user: credit.user,
      merchant_account: credit.merchant_account,
      credit:,
      issued_amount: balance_transaction_amount,
      holding_amount: balance_transaction_holding_amount
    )

    credit.balance = balance_transaction.balance
    credit.save!
    credit
  end

  def notify_user
    ContactingCreatorMailer.credit_notification(user.id, amount_cents, reason).deliver_later(queue: "critical")
  end

  def add_comment
    return if fee_retention_refund.present?

    comment_attrs = {
      content: "issued #{formatted_dollar_amount(amount_cents)} credit#{" — #{reason}" if reason.present?}.",
      comment_type: :credit
    }
    if crediting_user
      comment_attrs[:author_id] = crediting_user_id
    elsif chargebacked_purchase
      comment_attrs[:author_name] = "AutoCredit Chargeback Won (#{chargebacked_purchase.id})"
    elsif returned_payment
      comment_attrs[:author_name] = "AutoCredit Returned Payment (#{returned_payment.id})"
      comment_attrs[:content] = "issued adjustment due to currency conversion differences when payment #{returned_payment.id} returned."
    elsif refund
      comment_attrs[:author_name] = "AutoCredit PayPal Connect VAT refund (#{refund.purchase.id})"
    end
    user.comments.create(comment_attrs)
  end

  private
    def validate_associated_entity
      return if crediting_user || chargebacked_purchase || returned_payment || refund || financing_paydown_purchase || fee_retention_refund || backtax_agreement

      errors.add(:base, "A crediting user, chargebacked purchase, returned payment, refund, financing_paydown_purchase, fee_retention_refund or backtax_agreement must be provided.")
    end
end
