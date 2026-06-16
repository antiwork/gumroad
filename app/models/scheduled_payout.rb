# frozen_string_literal: true

class ScheduledPayout < ApplicationRecord
  include ExternalId

  ACTIONS = %w[refund payout hold].freeze
  STATUSES = %w[pending executed cancelled flagged held].freeze
  IN_PROGRESS_STATUSES = %w[pending flagged held].freeze

  AUTO_PAYOUT_THRESHOLD_CENTS = 100_000

  belongs_to :user
  belongs_to :created_by, class_name: "User", optional: true

  validates :action, presence: true, inclusion: { in: ACTIONS }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :processor, inclusion: { in: PayoutProcessorType.all }, allow_nil: true
  validates :delay_days, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :scheduled_at, presence: true
  validates :payout_amount_cents, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :no_in_progress_scheduled_payout_for_user, on: :create

  scope :pending, -> { where(status: "pending") }
  scope :executed, -> { where(status: "executed") }
  scope :cancelled, -> { where(status: "cancelled") }
  scope :flagged, -> { where(status: "flagged") }
  scope :held, -> { where(status: "held") }
  scope :in_progress, -> { where(status: IN_PROGRESS_STATUSES) }
  scope :due, -> { pending.where(scheduled_at: ..Time.current) }
  scope :for_user, ->(user) { where(user: user) }

  before_validation :set_scheduled_at, on: :create

  def execute!
    enqueue_refund = false
    process_payout = false
    send_chargeback_email = false
    result = nil

    with_lock do
      raise "Cannot execute a #{status} scheduled payout" if status != "pending"

      if user_has_active_chargebacks?
        update!(status: "flagged")
        send_chargeback_email = true
        result = :flagged
      elsif action == "payout" && payout_amount_cents.present? && payout_amount_cents > AUTO_PAYOUT_THRESHOLD_CENTS
        update!(status: "flagged")
        result = :flagged
      elsif action == "refund"
        raise "Cannot refund: user is not suspended" if !user.suspended?
        update!(status: "executed", executed_at: Time.current)
        enqueue_refund = true
        result = :executed
      elsif action == "payout"
        update!(status: "executed", executed_at: Time.current)
        process_payout = true
        result = :executed
      elsif action == "hold"
        update!(status: "held")
        result = :held
      end
    end

    # Process payout/refund outside the lock to avoid holding it during external API calls
    CreatorMailer.scheduled_payout_chargeback_hold(scheduled_payout_id: id).deliver_later if send_chargeback_email

    if process_payout
      begin
        payout_processor_type = processor.presence || user.current_payout_processor
        payment, payment_errors = Payouts.create_payment(
          Date.yesterday.to_s,
          payout_processor_type,
          user
        )

        if payment.blank?
          error_detail = if payment_errors.present?
            payment_errors.join(", ")
          else
            "No payable balance available"
          end
          raise "Payout failed: #{error_detail}"
        end

        if StripePayoutProcessor.cross_border_payout?(payment)
          # Funds transferred into a cross-border Connect account settle ~24h later. Defer the bank
          # payout (matching the automated payout path) instead of running it now — otherwise it
          # fails with balance_insufficient and reverses the transfer, losing the FX spread.
          ProcessPaymentWorker.perform_in(StripePayoutProcessor::CROSS_BORDER_PAYOUT_DELAY, payment.id)
        else
          PayoutProcessorType.get(payout_processor_type).process_payments([payment])

          if payment.reload.failed?
            raise "Payout failed: #{payment.errors.full_messages.first || "Payment processing failed"}"
          end
        end
      rescue => e
        update!(status: "pending", executed_at: nil)
        raise e
      end
    end

    RefundUnpaidPurchasesWorker.perform_async(user_id, created_by_id) if enqueue_refund

    result
  end

  def cancel!
    with_lock do
      raise "Cannot cancel a #{status} scheduled payout" if !%w[pending flagged].include?(status)

      update!(status: "cancelled")
    end
  end

  def pending?
    status == "pending"
  end

  def executed?
    status == "executed"
  end

  def cancelled?
    status == "cancelled"
  end

  def flagged?
    status == "flagged"
  end

  def held?
    status == "held"
  end

  def user_has_active_chargebacks?
    user.sales.chargedback.not_chargeback_reversed.exists? ||
      Dispute.where(seller_id: user_id).with_state(:created, :initiated, :formalized).exists?
  end

  private
    def set_scheduled_at
      self.scheduled_at ||= delay_days.days.from_now if delay_days.present?
    end

    def no_in_progress_scheduled_payout_for_user
      return unless user_id
      return unless self.class.for_user(user).in_progress.exists?

      errors.add(:base, "User already has a scheduled payout in progress")
    end
end
