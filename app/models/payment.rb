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
    after_transition processing: :failed, do: :add_payment_failure_reason_comment

    after_transition %i[processing unclaimed] => :completed, do: :mark_balances_as_paid
    after_transition any => :completed, do: :generate_default_abandoned_cart_workflow

    after_transition unclaimed: %i[cancelled reversed returned failed], do: :mark_balances_as_unpaid

    after_transition completed: :returned, do: :mark_balances_as_unpaid
    after_transition completed: :returned, do: :send_deposit_returned_email

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

  def humanized_failure_reason
    if processor == PayoutProcessorType::PAYPAL
      failure_reason.present? ? "#{failure_reason}: #{PAYPAL_MASS_PAY[failure_reason]}" : nil
    else
      failure_reason
    end
  end

  def reversed_by?(reversing_payout_id)
    processor_reversing_payout_id.present? && processor_reversing_payout_id == reversing_payout_id
  end

  def sync_with_payout_processor
    return unless NON_TERMINAL_STATES.include?(state)

    sync_with_paypal if processor == PayoutProcessorType::PAYPAL
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

    def split_payment_validation
      return if was_created_in_split_mode && split_payments_info.present?
      return if !was_created_in_split_mode && split_payments_info.blank?

      errors.add(:base, "A split payment needs to have the was_created_in_split_mode flag set and needs to have split_payments_info")
    end

    def sync_with_paypal
      return unless processor == PayoutProcessorType::PAYPAL

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
    rescue => e
      Rails.logger.error("Error syncing PayPal payout #{id}: #{e.message}")
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
      Bugsnag.notify(e)
    end
end
