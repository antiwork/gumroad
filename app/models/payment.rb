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

  # After this many consecutive failed/returned payouts to the same bank account, pause payouts and
  # flag the account for review. Each failed Stripe payout round-trips funds through the creator's
  # Connect account (transfer in, reverse out on failure), losing the FX spread every cycle and
  # booking it against the creator's balance. Without a cap, a bad bank account bounces weekly for
  # months and silently erodes real earnings. Pausing forces the payout details to be fixed first.
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

  scope :processed_by,            ->(processor) { where(processor:) }
  scope :processing,              -> { where(state: "processing") }
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

  def displayed_amount
    Money.new(amount_cents, currency).format(no_cents_if_whole: true, symbol: true, with_currency: currency != Currency::USD)
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

  def send_payout_failure_email
    # This would already be done from callback/ We dont't to clean that up rn
    return if failure_reason === FailureReason::CANNOT_PAY

    ContactingCreatorMailer.cannot_pay(id).deliver_later(queue: "critical")

    user.payout_date_of_last_payment_failure_email = payout_period_end_date
    user.save!
  end

  def send_debit_card_limit_email
    ContactingCreatorMailer.debit_card_limit_reached(id).deliver_later(queue: "critical")
  end

  # Tell the seller their PayPal account cannot receive the payout, and that we have stopped
  # retrying it.
  #
  # This has its own "already sent" marker rather than sharing
  # payout_date_of_last_payment_failure_email with the other payout-failure emails. That column is
  # written by any failure email in the period, so sharing it would mean an unrelated earlier email
  # silently swallows this one — and because the retries stop here, there is no later period in
  # which it would be sent instead. The seller would never be told why their money stopped moving.
  def send_paypal_terminal_failure_email
    return if user.payout_date_of_last_paypal_terminal_failure_email.present? &&
              Date.parse(user.payout_date_of_last_paypal_terminal_failure_email) >= payout_period_end_date

    ContactingCreatorMailer.paypal_payout_permanently_failed(id).deliver_later(queue: "critical")

    user.payout_date_of_last_paypal_terminal_failure_email = payout_period_end_date
    # Skip validations: this is bookkeeping about an email, and the seller rows that reach here are
    # exactly the ones likely to be invalid for unrelated reasons (incomplete payout details). A
    # raise here would roll back the whole failure transition, leaving the payout stuck in
    # `processing`, which then blocks every future payout for that seller with nothing to show why.
    user.save!(validate: false)
  end

  def humanized_failure_reason
    if processor == PayoutProcessorType::PAYPAL
      failure_reason.present? ? "#{failure_reason}: #{PAYPAL_MASS_PAY[failure_reason]}" : nil
    else
      failure_reason
    end
  end

  # True when PayPal rejected this payout for a reason that describes the destination PayPal
  # account rather than this attempt, so the seller has to change something before the money can
  # move. This is what drives the seller-facing explanation and email.
  # See Payment::FailureReason::EXPLAINED_PAYPAL_FAILURE_REASONS.
  def explained_paypal_failure?
    processor == PayoutProcessorType::PAYPAL &&
      FailureReason::EXPLAINED_PAYPAL_FAILURE_REASONS.include?(failure_reason)
  end

  # True when we additionally stop re-sending this payout to the same address, because no action
  # inside the seller's PayPal account can make it succeed. A strict subset of the above — see
  # Payment::FailureReason::RETRY_BLOCKING_PAYPAL_FAILURE_REASONS for why 14159 is explained but
  # still retried.
  def terminal_paypal_failure?
    processor == PayoutProcessorType::PAYPAL &&
      FailureReason::TERMINAL_PAYPAL_FAILURE_REASONS.include?(failure_reason)
  end

  # What to tell the seller to do about a terminal PayPal rejection, and what to expect after.
  #
  # Both halves are per-seller. Bank transfer is only a real option where Gumroad supports it —
  # most sellers hitting these rejections are in PayPal-only countries. And fixing the payout
  # method is only enough when payouts for the account are otherwise free to run: under a hold,
  # Payouts.is_user_payable rejects before it ever reaches the PayPal processor, so the seller has
  # to be told to come to us rather than to expect money on the next payout date.
  #
  # A terminal rejection no longer causes a hold itself (see pause_payouts_after_repeated_failures),
  # but the hundreds of sellers who were already stuck before that stopped are still holding one,
  # as is anyone paused for an unrelated reason, so the paused wording still has to exist.
  def terminal_paypal_failure_seller_solution
    fix = if user.can_setup_bank_payouts?
      FailureReason::TERMINAL_PAYPAL_FAILURE_SELLER_FIX_WITH_BANK
    else
      FailureReason::TERMINAL_PAYPAL_FAILURE_SELLER_FIX_PAYPAL_ONLY
    end

    # Only a hold WE placed. A seller who paused their own payouts in their settings can resume
    # them whenever they like, so sending them to support to have it "reviewed" would be busywork
    # for both of us. They still cannot be told plainly to expect the next payout date, because the
    # payout gate (Payouts.is_user_payable) checks the broader payouts_paused? and skips them while
    # their own pause is on — so they get wording that names the switch they own.
    next_step = if user.payouts_paused_internally?
      FailureReason::TERMINAL_PAYPAL_FAILURE_SELLER_NEXT_STEP_WHILE_PAUSED
    elsif user.payouts_paused_by_user?
      FailureReason::TERMINAL_PAYPAL_FAILURE_SELLER_NEXT_STEP_WHILE_SELF_PAUSED
    else
      FailureReason::TERMINAL_PAYPAL_FAILURE_SELLER_NEXT_STEP
    end

    "#{fix} #{next_step}"
  end

  # The whole seller-facing explanation for a terminal PayPal rejection, as one sentence pair.
  #
  # Three places write this note — the payout that fails, the payout run that finds the seller can
  # no longer see it, and the one-time backfill for sellers who were stuck before any of this
  # existed. They have to write identical text, because the code that decides whether an
  # explanation is already in front of the seller recognises it by its wording.
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

      # A terminal PayPal rejection is handled by a narrower mechanism and must not also pause the
      # account. Pausing would contradict what we just told the seller: the note and email say to
      # add a bank account and they will be paid on the next payout date, but a paused account is
      # skipped before the payout method is even considered, so they would follow our instructions
      # and still not get paid until support noticed and resumed them by hand. That is how these
      # sellers ended up with nothing but "payouts were paused by the system" to go on
      # (gumroad-private#1478).
      #
      # Nothing is lost by skipping the pause here. This check exists to stop us hammering a
      # destination that keeps rejecting us, and the terminal block does that job more precisely:
      # it is keyed on the PayPal address rather than the whole account, it engages on the first
      # rejection instead of the third, and it lifts on its own when the seller fixes their payout
      # details rather than needing a human to resume them.
      #
      # Only the retry-blocking codes are skipped, because only those have something narrower doing
      # the job instead. A rejection we still retry (14159) has no such replacement, so its
      # failures do count here and a seller who never acts is eventually paused — which is what this
      # check is for, since otherwise we would re-send a rejected item every week forever. They are
      # not left in the dark by that pause: Payouts.is_user_payable suppresses the weekly
      # "payouts were paused" note while the PayPal explanation is the newest one they can see, and
      # it asks that question about the wider EXPLAINED set precisely so this case is covered.
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
      # Don't count the rejections that are already handled by the terminal-failure block, for the
      # same reason this method returns early for them: a hold undoes what we told the seller to do.
      # Without this, a terminal rejection still contributes to the count and a couple of unrelated
      # later rows can push the account over the threshold — unclaimed payouts to the same address
      # turning into returns weeks afterwards is enough — and the seller who followed our
      # instructions ends up held anyway, which is the outcome this whole change removes.
      # `failure_reason` is NULL on most non-PayPal rows, and NOT IN never matches NULL, so the
      # NULL case has to be spelled out or those rows silently stop counting.
      failed_payouts = failed_payouts.where(
        "failure_reason IS NULL OR failure_reason NOT IN (?)",
        FailureReason::TERMINAL_PAYPAL_FAILURE_REASONS
      )
      failed_payouts = failed_payouts.where("created_at > ?", last_completed_at) if last_completed_at
      failed_count = failed_payouts.count
      return if failed_count < MAX_CONSECUTIVE_FAILED_PAYOUTS

      # Flag and comment must land together. The comment is what identifies WHICH automatic check
      # paused this account (both write source "system"), so a window where the flag is set but the
      # comment is not lets a reader attribute the hold to the wrong check — specifically,
      # ReleaseChargebackRatePayoutPauseForSellerJob would see an older chargeback comment as the
      # current reason and lift a hold this code just applied. No explicit transaction is needed
      # here: state_machines-activerecord already wraps the whole transition, including this
      # after_transition callback, in one. The spec pins that so a future refactor out of the state
      # machine can't quietly reintroduce the gap.
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
            mark_failed!
            if stripe_payout["failure_code"].present?
              self.failure_reason = stripe_payout["failure_code"]
              save!
            end
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

      send_payout_failure_email if send_failure_email
      StripePayoutProcessor.reverse_internal_transfer!(self) if needs_reverse_transfer
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
