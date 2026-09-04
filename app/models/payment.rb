# frozen_string_literal: true

class Payment < ApplicationRecord
  include ExternalId, Payment::Stats, JsonData, FlagShihTzu, TimestampScopes, Payment::FailureReason

  CREATING = "creating"
  PROCESSING = "processing"
  UNCLAIMED = "unclaimed"
  COMPLETED = "completed"
  FAILED = "failed"
  CANCELLED = "cancelled"
  REVERSED = "reversed"
  RETURNED = "returned"
  NON_TERMINAL_STATES = [CREATING, PROCESSING, UNCLAIMED, COMPLETED].freeze

  # Consecutive failed/returned payouts to the same destination before we pause. A failed Stripe
  # payout round-trips through Connect and books the FX spread against the creator; without a cap
  # a bad bank account bounces weekly and erodes earnings.
  MAX_CONSECUTIVE_FAILED_PAYOUTS = 3

  belongs_to :user, optional: true
  belongs_to :bank_account, optional: true
  has_and_belongs_to_many :balances, join_table: "payments_balances"

  has_one :credit, foreign_key: :returned_payment_id

  has_flags 1 => :was_created_in_split_mode,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  attr_json_data_accessor :split_payments_info
  attr_json_data_accessor :arrival_date
  attr_json_data_accessor :payout_type
  attr_json_data_accessor :gumroad_fee_cents
  attr_json_data_accessor :error_message

  # Payment state transitions:
  #
  #  creating
  #      ↓
  # processing → → → → → → → → → → → → → → → → ↓
  #      ↓                             ↓       ↓
  #      ↓ → → → → → failed        cancelled   ↓
  #      ↓             ↑       ↗               ↓
  #      ↓ → → → → unclaimed → → → reversed ← ←↓
  #      ↓             ↓       ↘︎               ↓
  #      ↓ → → → → completed → → → returned ← ←↓
  #
  state_machine(:state, initial: :creating) do
    event :mark_processing do
      transition creating: :processing
    end

    event :mark_cancelled do
      transition processing: :cancelled
      transition unclaimed: :cancelled, if: ->(payment) { payment.processor == PayoutProcessorType::PAYPAL }
    end

    event :mark_completed do
      transition %i[processing unclaimed] => :completed
    end

    event :mark_failed do
      transition %i[creating processing] => :failed
    end

    event :mark_reversed do
      transition %i[processing unclaimed] => :reversed
    end

    event :mark_returned do
      transition %i[processing unclaimed] => :returned
      transition completed: :returned, if: ->(payment) { payment.processor != PayoutProcessorType::PAYPAL }
    end

    event :mark_unclaimed do
      transition processing: :unclaimed, if: ->(payment) { payment.processor == PayoutProcessorType::PAYPAL }
    end

    before_transition any => :failed, do: ->(payment, transition) { payment.failure_reason = transition.args.first }
    after_transition %i[creating processing] => %i[cancelled failed], do: :mark_balances_as_unpaid
    after_transition processing: :failed, do: :send_cannot_pay_email, if: ->(payment) { payment.failure_reason == FailureReason::CANNOT_PAY }
    after_transition processing: :failed, do: :send_debit_card_limit_email, if: ->(payment) { payment.failure_reason == FailureReason::DEBIT_CARD_LIMIT }
    # Invalidation before the note/email: both claim we removed the address, and
    # paypal_payout_address_invalidated? reads the account. After would deny it.
    after_transition processing: :failed, do: :invalidate_paypal_payout_address, if: ->(payment) { payment.terminal_paypal_failure? }
    after_transition processing: :failed, do: :send_paypal_terminal_failure_email, if: ->(payment) { payment.explained_paypal_failure? }
    after_transition processing: :failed, do: :add_payment_failure_reason_comment

    after_transition %i[processing unclaimed] => :completed, do: :mark_balances_as_paid
    after_transition any => :completed, do: :generate_default_abandoned_cart_workflow

    after_transition unclaimed: %i[cancelled reversed returned failed], do: :mark_balances_as_unpaid
    after_transition processing: %i[reversed returned], do: :mark_balances_as_unpaid

    after_transition completed: :returned, do: :mark_balances_as_unpaid
    after_transition completed: :returned, do: :send_deposit_returned_email

    after_transition any => :failed, do: :pause_payouts_after_repeated_failures
    after_transition any => :returned, do: :pause_payouts_after_repeated_failures

    after_transition processing: %i[completed unclaimed], do: :send_deposit_email

    after_transition any => any, :do => :log_transition

    state any do
      validates_presence_of :processor
    end

    state any - %i[creating processing] do
      validates_presence_of :correlation_id, if: proc { |p| p.processor == PayoutProcessorType::PAYPAL }
    end

    state any - %i[creating processing cancelled failed] do
      validates :stripe_transfer_id, :stripe_connect_account_id, presence: true, if: proc { |p| p.processor == PayoutProcessorType::STRIPE }
    end

    state :completed do
      validates_presence_of :txn_id, if: proc { |p| p.processor == PayoutProcessorType::PAYPAL }
      validates_presence_of :amount_cents_in_local_currency, if: proc { |p| p.processor == PayoutProcessorType::ZENGIN }
      validates_presence_of :processor_fee_cents
    end
  end

  validate :split_payment_validation

  # A payment stuck in `processing` past this age is treated as settled-but-unconfirmed
  # rather than still in flight, so it stops blocking the next payout run. See gp#1918
  # for the corridor whose completion webhook lags this long.
  STUCK_PROCESSING_AGE = 5.days

  scope :processed_by,            ->(processor) { where(processor:) }
  scope :processing,              -> { where(state: "processing") }
  scope :blocking_next_payout,    -> { where(state: "processing").where("created_at > ?", STUCK_PROCESSING_AGE.ago) }
  scope :completed,               -> { where(state: "completed") }
  scope :completed_or_processing, -> { where("state = 'completed' or state = 'processing'") }
  scope :failed,                  -> { where(state: "failed").order(id: :desc) }
  scope :failed_cannot_pay,       -> { failed.where(failure_reason: "cannot_pay") }
  scope :displayable,             -> { where("created_at >= ?", PayoutsHelper::OLDEST_DISPLAYABLE_PAYOUT_PERIOD_END_DATE) }

  def mark(state)
    send("mark_#{state}")
  end

  def mark!(state)
    send("mark_#{state}!")
  end

  def displayed_amount(no_cents_if_whole: true)
    Money.new(amount_cents, currency).format(no_cents_if_whole:, symbol: true, with_currency: currency != Currency::USD)
  end

  def credits
    Credit.where(balance_id: balances)
  end

  def credit_amount_cents
    credits.where(fee_retention_refund_id: nil).sum("amount_cents")
  end

  def send_deposit_email
    CustomerLowPriorityMailer.deposit(id).deliver_later(queue: "low")
  end

  def send_deposit_returned_email
    ContactingCreatorMailer.payment_returned(id).deliver_later(queue: "critical")
  end

  def send_cannot_pay_email
    return if user.payout_date_of_last_payment_failure_email.present? &&
              Date.parse(user.payout_date_of_last_payment_failure_email) >= payout_period_end_date

    ContactingCreatorMailer.cannot_pay(id).deliver_later(queue: "critical")

    user.payout_date_of_last_payment_failure_email = payout_period_end_date
    user.save!
  end

  # Notifying the seller must never decide whether Gumroad's money gets reversed. Both callers run
  # this after `mark_failed!` has already returned the balances to `unpaid` but before the internal
  # transfer is reversed, so a raise here would strand the transfer with the seller unpaused.
  def send_payout_failure_email_best_effort
    send_payout_failure_email
  rescue => e
    # Discard the unpersisted `payout_date_of_last_payment_failure_email` assignment. The reversal
    # and the payout hold both take `user.with_lock`, and `lock!` raises outright on a record with
    # unsaved changes — so leaving `user` dirty here turns a mail failure back into the stranded
    # transfer this method exists to prevent.
    user.reload
    ErrorNotifier.notify(e, payment_id: id, user_id:,
                            action_required: "Payout failure email did not send. The payout reversal and any hold still ran.")
  end

  def send_payout_failure_email
    # Both of these are already mailed by the `processing => failed` transition callbacks, which now
    # see the reason because it is written by the transition itself rather than a later save.
    return if failure_reason.in?([FailureReason::CANNOT_PAY, FailureReason::DEBIT_CARD_LIMIT])

    ContactingCreatorMailer.cannot_pay(id).deliver_later(queue: "critical")

    user.payout_date_of_last_payment_failure_email = payout_period_end_date
    user.save!
  end

  def send_debit_card_limit_email
    ContactingCreatorMailer.debit_card_limit_reached(id).deliver_later(queue: "critical")
  end

  # Own "already sent" marker: payout_date_of_last_payment_failure_email is written by any
  # failure email in the period, so sharing it would swallow this one. Retries stop here,
  # so there is no later period to send it instead.
  def send_paypal_terminal_failure_email
    return if user.payout_date_of_last_paypal_terminal_failure_email.present? &&
              Date.parse(user.payout_date_of_last_paypal_terminal_failure_email) >= payout_period_end_date

    ContactingCreatorMailer.paypal_payout_permanently_failed(id).deliver_later(queue: "critical")

    user.payout_date_of_last_paypal_terminal_failure_email = payout_period_end_date
    # Skip validations: these sellers are often invalid for unrelated reasons. A raise rolls
    # back the failure transition and leaves the payout stuck in processing.
    user.save!(validate: false)
  end

  # Only retry-blocking rejections invalidate — 14159 is repairable in place and we still
  # retry it. Stash the address in invalidated_paypal_payout_address (lookups key on it;
  # support can restore). No method on file = cannot publish / not Discover-recommendable,
  # same as never having added one.
  def invalidate_paypal_payout_address
    address = nil

    # Same lock UpdatePayoutMethod takes. Without it, a replacement address saved between
    # the comparison and this write is overwritten with "".
    user.with_lock do
      address = user.payment_address
      next if address.blank?
      # Only the address this payout was sent to — not one the seller has since replaced.
      next address = nil unless payment_address == address
      # Not an address a later payout already succeeded to (failure rows can transition late).
      last_completed_at = user.payments.completed.where(processor: PayoutProcessorType::PAYPAL, payment_address: address)
                              .maximum(:created_at)
      next address = nil if last_completed_at.present? && last_completed_at > created_at

      user.payment_address = ""
      user.invalidated_paypal_payout_address = address
      # Skip validations — same reason as send_paypal_terminal_failure_email.
      user.save!(validate: false)
    end

    return if address.blank?

    user.add_payout_note(
      content: "PayPal payout address #{address} removed because PayPal permanently refused it (#{failure_reason}). " \
               "To restore it, set payment_address back and clear invalidated_paypal_payout_address.",
      seller_visible: false
    )
  end

  def humanized_failure_reason
    if processor == PayoutProcessorType::PAYPAL
      failure_reason.present? ? "#{failure_reason}: #{PAYPAL_MASS_PAY[failure_reason]}" : nil
    else
      failure_reason
    end
  end

  # Destination-account rejection (not this attempt) — drives the seller-facing explanation.
  def explained_paypal_failure?
    processor == PayoutProcessorType::PAYPAL &&
      FailureReason::EXPLAINED_PAYPAL_FAILURE_REASONS.include?(failure_reason)
  end

  # Stop re-sending to this address. Subset of explained — 14159 is explained but still retried.
  def terminal_paypal_failure?
    processor == PayoutProcessorType::PAYPAL &&
      FailureReason::TERMINAL_PAYPAL_FAILURE_REASONS.include?(failure_reason)
  end

  # Seller can clear this on the PayPal account they already use (add USD). Copy must not
  # claim retries have stopped.
  def repairable_in_place_paypal_failure?
    processor == PayoutProcessorType::PAYPAL &&
      FailureReason::REPAIRABLE_IN_PLACE_PAYPAL_FAILURE_REASONS.include?(failure_reason)
  end

  # PayPal locked/deactivated the receiving account. Only they can lift it — don't blame country.
  def locked_account_paypal_failure?
    processor == PayoutProcessorType::PAYPAL &&
      FailureReason::LOCKED_ACCOUNT_PAYPAL_FAILURE_REASONS.include?(failure_reason)
  end

  # No remaining payout method: PayPal refuses the country and we don't offer bank transfer.
  # Read the terminal list rather than naming 3148; the copy only holds while that list stays
  # country-scoped (see NO_OTHER_PAYPAL_ACCOUNT_HELPS_REASONS).
  def paypal_failure_without_available_payout_rail?
    terminal_paypal_failure? &&
      !repairable_in_place_paypal_failure? &&
      !user.can_setup_bank_payouts?
  end

  # Invalidation happened for THIS payout's address — not merely "the account has a removed
  # address on record" (a later connected PayPal would otherwise be described as removed).
  def paypal_payout_address_invalidated?
    user.invalidated_paypal_payout_address.present? &&
      user.invalidated_paypal_payout_address == payment_address
  end

  # Bank transfer only where we support it (most of these sellers are PayPal-only). Under a
  # hold, is_user_payable rejects before PayPal, so don't promise the next payout date.
  # Terminal rejection no longer holds the account, but pre-existing and unrelated holds
  # still need the paused wording.
  def terminal_paypal_failure_seller_solution
    fix = if paypal_failure_without_available_payout_rail?
      FailureReason::TERMINAL_PAYPAL_FAILURE_SELLER_SOLUTION_NO_PAYOUT_RAIL
    elsif locked_account_paypal_failure?
      # Only PayPal can unlock — neither branch sends them after a differently-registered
      # PayPal account; the country was never the problem.
      if user.can_setup_bank_payouts?
        FailureReason::TERMINAL_PAYPAL_FAILURE_SELLER_FIX_LOCKED_ACCOUNT_WITH_BANK
      else
        FailureReason::TERMINAL_PAYPAL_FAILURE_SELLER_FIX_LOCKED_ACCOUNT_PAYPAL_ONLY
      end
    elsif repairable_in_place_paypal_failure?
      # Clear this on the account they already use — see REPAIRABLE_IN_PLACE_PAYPAL_FAILURE_REASONS.
      if user.can_setup_bank_payouts?
        FailureReason::TERMINAL_PAYPAL_FAILURE_SELLER_FIX_IN_PLACE_WITH_BANK
      else
        FailureReason::TERMINAL_PAYPAL_FAILURE_SELLER_FIX_IN_PLACE_PAYPAL_ONLY
      end
    elsif user.can_setup_bank_payouts?
      if paypal_payout_address_invalidated?
        FailureReason::TERMINAL_PAYPAL_FAILURE_SELLER_FIX_WITH_BANK
      else
        FailureReason::TERMINAL_PAYPAL_FAILURE_SELLER_FIX_CONNECTED_WITH_BANK
      end
    else
      if paypal_payout_address_invalidated?
        FailureReason::TERMINAL_PAYPAL_FAILURE_SELLER_FIX_PAYPAL_ONLY
      else
        FailureReason::TERMINAL_PAYPAL_FAILURE_SELLER_FIX_CONNECTED_PAYPAL_ONLY
      end
    end

    # Internal and self-pause are independent (all four combos). Self-pause: they can resume
    # themselves — don't send them to support — but is_user_payable still skips them, so don't
    # promise the next date. When both are on, name both.
    next_step = if user.payouts_paused_internally? && user.payouts_paused_by_user?
      FailureReason::TERMINAL_PAYPAL_FAILURE_SELLER_NEXT_STEP_WHILE_PAUSED_AND_SELF_PAUSED
    elsif user.payouts_paused_internally?
      FailureReason::TERMINAL_PAYPAL_FAILURE_SELLER_NEXT_STEP_WHILE_PAUSED
    elsif user.payouts_paused_by_user?
      FailureReason::TERMINAL_PAYPAL_FAILURE_SELLER_NEXT_STEP_WHILE_SELF_PAUSED
    else
      FailureReason::TERMINAL_PAYPAL_FAILURE_SELLER_NEXT_STEP
    end

    "#{fix} #{next_step}"
  end

  # Three writers (the failing payout, the run that finds they can no longer see it, the
  # one-time backfill) must emit identical text — presence is recognised by wording.
  def terminal_paypal_failure_seller_note
    "Your payout on #{created_at.to_fs(:formatted_date_full_month)} could not be sent because " \
      "#{FailureReason::TERMINAL_PAYPAL_FAILURE_SELLER_REASONS.fetch(failure_reason)}. " \
      "#{terminal_paypal_failure_seller_solution}"
  end

  def reversed_by?(reversing_payout_id)
    processor_reversing_payout_id.present? && processor_reversing_payout_id == reversing_payout_id
  end

  def sync_with_payout_processor
    return unless NON_TERMINAL_STATES.include?(state)

    case processor
    when PayoutProcessorType::PAYPAL
      sync_with_paypal
    when PayoutProcessorType::STRIPE
      sync_with_stripe
    end
  end

  def as_json(options = {})
    json = {
      id: external_id,
      amount: format("%.2f", (amount_cents || 0) / 100.0),
      currency: currency,
      status: state,
      created_at: created_at,
      processed_at: state == COMPLETED ? updated_at : nil,
      payment_processor: processor,
      bank_account_visual: bank_account&.account_number_visual,
      paypal_email: payment_address
    }

    if options[:include_sales]
      json[:sales] = successful_sales.map(&:external_id)
      json[:refunded_sales] = refunded_sales.map(&:external_id)
      json[:disputed_sales] = disputed_sales.map(&:external_id)
    end

    if options[:include_transactions]
      json[:transactions] = Exports::Payouts::Api.new(self).perform
    end

    json
  end

  def successful_sales
    Purchase.where(purchase_success_balance_id: balance_ids)
            .includes(:link)
            .distinct
            .order(created_at: :desc, id: :desc)
  end

  def refunded_sales
    Purchase.where(purchase_refund_balance_id: balance_ids)
            .includes(:link)
            .distinct
            .order(created_at: :desc, id: :desc)
  end

  def disputed_sales
    Purchase.where(purchase_chargeback_balance_id: balance_ids)
            .includes(:link)
            .distinct
            .order(created_at: :desc, id: :desc)
  end

  private
    def balance_ids
      @balance_ids ||= balances.pluck(:id)
    end

    def mark_balances_as_paid
      balances.each(&:mark_paid!)
    end

    def mark_balances_as_unpaid
      balances.each(&:mark_unpaid!)
    end

    def log_transition
      logger.info "Payment: payment ID #{id} transitioned to #{state}"
    end

    def pause_payouts_after_repeated_failures
      return if user.nil? || user.payouts_paused?

      # Terminal PayPal rejection has a narrower block (keyed on the address, first rejection,
      # lifts when they fix details). Don't also pause: the note/email tell them to add a bank
      # account and they'll be paid next date, but a paused account is skipped before payout
      # method is considered (gumroad-private#1478). Only retry-blocking codes skip the pause.
      # 14159 still counts — nothing else stops weekly retries. is_user_payable suppresses the
      # weekly pause note while the PayPal explanation is newest (EXPLAINED set, so 14159 is
      # covered).
      return if terminal_paypal_failure?

      if bank_account_id.present?
        destination = "bank account"
        payouts_to_destination = user.payments.where(bank_account_id:)
      elsif processor == PayoutProcessorType::PAYPAL && payment_address.present?
        destination = "PayPal account"
        payouts_to_destination = user.payments.where(processor: PayoutProcessorType::PAYPAL, payment_address:)
      else
        return
      end

      last_completed_at = payouts_to_destination.completed.maximum(:created_at)
      failed_payouts = payouts_to_destination.where(state: [FAILED, RETURNED])
      # Exclude terminal-failure reasons so a later unrelated return can't still trip the hold.
      # failure_reason is NULL on most non-PayPal rows; NOT IN never matches NULL, so spell
      # the NULL case out or those rows stop counting.
      failed_payouts = failed_payouts.where(
        "failure_reason IS NULL OR failure_reason NOT IN (?)",
        FailureReason::TERMINAL_PAYPAL_FAILURE_REASONS
      )
      failed_payouts = failed_payouts.where("created_at > ?", last_completed_at) if last_completed_at
      # Internal/transient failures say nothing about the destination. IS NULL is load-bearing:
      # NOT IN alone drops NULL rows (most failures) and disables this check.
      failed_payouts = failed_payouts.where(
        "failure_reason IS NULL OR failure_reason NOT IN (?)",
        TRANSIENT_REASONS + INTERNAL_RECONCILIATION_REASONS
      )
      failed_count = failed_payouts.count
      return if failed_count < MAX_CONSECUTIVE_FAILED_PAYOUTS

      # Flag and comment must land together — both write source "system", so a missing comment
      # lets ReleaseChargebackRatePayoutPauseForSellerJob treat an older chargeback comment as
      # the current reason and lift this hold. The state machine already wraps this callback
      # in one transaction; the spec pins that.
      user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
      user.comments.create!(
        content: "Payouts paused automatically after #{failed_count} consecutive failed payouts to the same #{destination}. Verify the seller's payout details before resuming.",
        comment_type: Comment::COMMENT_TYPE_ON_PROBATION,
        author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:repeated_failed_payouts]
      )
    end

    def split_payment_validation
      return if was_created_in_split_mode && split_payments_info.present?
      return if !was_created_in_split_mode && split_payments_info.blank?

      errors.add(:base, "A split payment needs to have the was_created_in_split_mode flag set and needs to have split_payments_info")
    end

    def sync_with_paypal
      return unless processor == PayoutProcessorType::PAYPAL

      with_lock do
        # For split mode payouts we only sync if we have the txn_ids of individual split parts,
        # and do not look up or search by PayPal email address.
        # As these are large payouts (usually over $5k or $10k), they include multiple parts with same amount,
        # like 3 split parts of $3k each or similar.
        if was_created_in_split_mode?
          split_payments_info.each_with_index do |split_payment_info, index|
            new_payment_state =
              PaypalPayoutProcessor.get_latest_payment_state_from_paypal(split_payment_info["amount_cents"],
                                                                         split_payment_info["txn_id"],
                                                                         created_at.beginning_of_day - 1.day,
                                                                         split_payment_info["state"])
            split_payments_info[index]["state"] = new_payment_state
          end
          save!

          if split_payments_info.map { _1["state"] }.uniq.count > 1
            errors.add :base, "Not all split payout parts are in the same state for payout #{id}. This needs to be handled manually."
          else
            PaypalPayoutProcessor.update_split_payment_state(self)
          end
        else
          paypal_response = PaypalPayoutProcessor.search_payment_on_paypal(amount_cents:, transaction_id: txn_id, payment_address:,
                                                                           start_date: created_at.beginning_of_day - 1.day,
                                                                           end_date: created_at.end_of_day + 1.day)
          if paypal_response.nil?
            transition_to_new_state("failed")
          else
            transition_to_new_state(paypal_response[:state], transaction_id: paypal_response[:transaction_id],
                                                             correlation_id: paypal_response[:correlation_id],
                                                             paypal_fee: paypal_response[:paypal_fee])
          end
        end
      end
    rescue => e
      Rails.logger.error("Error syncing PayPal payout #{id}: #{e.message}")
      errors.add :base, e.message
    end

    def sync_with_stripe
      return if processor != PayoutProcessorType::STRIPE
      return if [CREATING, PROCESSING].exclude?(state)

      needs_reverse_transfer = false
      send_failure_email = false

      if stripe_transfer_id.present? && stripe_connect_account_id.present?
        stripe_payout = Stripe::Payout.retrieve(stripe_transfer_id, { stripe_account: stripe_connect_account_id })
        with_lock do
          case stripe_payout["status"]
          when "paid"
            self.processor_fee_cents ||= 0
            self.arrival_date = stripe_payout["arrival_date"]
            mark_processing! if state == CREATING
            mark_completed!
          when "canceled"
            mark_processing! if state == CREATING
            mark_cancelled!
            needs_reverse_transfer = true
          when "failed"
            # The reason rides along with the transition's own write, same as the webhook path. A
            # `save!` of its own ran after the balances were already back to `unpaid`, so a raise
            # from it skipped the reversal below and left Gumroad's funds on the seller's connected
            # account with the payment already terminal — and this caller swallows the exception into
            # `errors`, which SyncStuckPayoutsJob discards, so it was silent.
            mark_failed!(stripe_payout["failure_code"].presence)
            needs_reverse_transfer = true
            send_failure_email = true
          end
        end
      else
        with_lock do
          mark_failed!
        end
        needs_reverse_transfer = true
      end

      send_payout_failure_email_best_effort if send_failure_email
      # Hold-aware: the `rescue` below turns a failed reversal into an `errors.add`, which
      # SyncStuckPayoutsJob discards. Without the hold, Gumroad's funds stay on the connected
      # account while `mark_failed!`/`mark_cancelled!` have already returned the balances to
      # `unpaid`, so the seller's next scheduled batch would transfer the same money again.
      StripePayoutProcessor.reverse_internal_transfer_or_hold_payouts!(self, failure_reason, reraise: true) if needs_reverse_transfer
    rescue => e
      Rails.logger.error("Error syncing Stripe payout #{id}: #{e.message}")
      errors.add :base, e.message
    end

    def transition_to_new_state(new_state, transaction_id: nil, correlation_id: nil, paypal_fee: nil)
      return unless NON_TERMINAL_STATES.include?(state)
      return unless new_state.present?
      return if new_state == state
      return unless [FAILED, UNCLAIMED, COMPLETED, CANCELLED, REVERSED, RETURNED].include?(new_state)

      self.txn_id = transaction_id if transaction_id.present? && self.txn_id.blank?
      self.correlation_id = correlation_id if correlation_id.present? && self.correlation_id.blank?
      self.processor_fee_cents = (100 * paypal_fee.to_f).round.abs if paypal_fee.present? && self.processor_fee_cents.blank?

      # If payout got stuck in 'creating', transition it to 'processing' state
      # so we can transition it to whatever the new state is on PayPal.
      mark!(PROCESSING) if state?(CREATING)

      if new_state == FAILED && transaction_id.blank?
        mark_failed!("Transaction not found")
      else
        mark!(new_state)
      end
    end

    def generate_default_abandoned_cart_workflow
      DefaultAbandonedCartWorkflowGeneratorService.new(seller: user).generate if user.present?
    rescue => e
      Rails.logger.error("Failed to generate default abandoned cart workflow for user #{user.id}: #{e.message}")
      ErrorNotifier.notify(e)
    end
end
