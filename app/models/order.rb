# frozen_string_literal: true

class Order < ApplicationRecord
  include ExternalId, SecureExternalId, Orderable, FlagShihTzu

  belongs_to :purchaser, class_name: "User", optional: true
  has_many :order_purchases, dependent: :destroy
  has_many :purchases, through: :order_purchases, dependent: :destroy

  has_many :charges, dependent: :destroy
  has_one :cart, dependent: :destroy

  attr_accessor :setup_future_charges

  has_flags 1 => :DEPRECATED_seller_receipt_enabled,
            2 => :partially_successful,
            column: "flags",
            flag_query_mode: :bit_operator,
            check_for_column: false

  delegate :card_type, :card_visual, :full_name, to: :purchase_with_payment_as_orderable, allow_nil: true

  after_save :schedule_review_reminder!, if: :should_schedule_review_reminder?

  def receipt_for_gift_receiver?
    raise NotImplementedError, "Not supported for multi-item orders" if successful_purchases.count > 1
    purchase = purchase_as_orderable
    return false if purchase.nil?

    purchase.is_gift_receiver_purchase?
  end

  def receipt_for_gift_sender?
    raise NotImplementedError, "Not supported for multi-item orders" if successful_purchases.count > 1
    purchase = purchase_as_orderable
    return false if purchase.nil?

    purchase.is_gift_sender_purchase?
  end

  def email
    purchase_as_orderable&.email
  end

  def locale
    purchase_as_orderable&.locale
  end

  def test?
    purchase_as_orderable&.is_test_purchase? || false
  end

  def send_charge_receipts
    return unless uses_charge_receipt?

    successful_charges.each do
      next if _1.receipt_sent?
      SendChargeReceiptJob.set(queue: _1.purchases_requiring_stamping.any? ? "default" : "critical").perform_async(_1.id)
    end
  end

  def successful_charges
    @_successful_charges ||= charges.select { _1.successful_purchases.any? }
  end

  # Partial success is a reachable outcome of one checkout — `Order::ChargeService` rescues per
  # seller group, so an exception in seller B's group leaves seller A's charge captured — and until
  # this is recorded the outcome exists only as the derived states of the child purchases, so
  # nothing can query or reconcile it.
  #
  # No "all line items settled" guard: once the order holds both a success and a failure the
  # predicate can never go back to false (purchase states are terminal), so a still-in-progress
  # sibling cannot change the answer, only when it is written.
  #
  # `update_all` with a bitwise OR rather than a save: sibling line items in the same order settle
  # concurrently, and a read-modify-write of `flags` would let one overwrite the other's bits.
  # It also keeps this derived bookkeeping out of `after_save :schedule_review_reminder!` — the
  # order row is otherwise saved only at creation, so an ordinary save from the charge path would
  # fire the reminder hook that the purchase-success transition owns.
  #
  # Read the sibling states from the DB, never from a loaded association: this runs from
  # RecordOrderChargeOutcomeJob after each line item's own transaction has committed, and the
  # sibling that settled concurrently is only visible on a fresh read.
  def record_charge_outcome!
    partial = purchases.all_success_states.exists? && purchases.checkout_failed.exists?
    return if partially_successful? == partial

    bit = self.class.flag_mapping["flags"][:partially_successful]
    sql = partial ? "flags = flags | #{bit}" : "flags = flags & ~#{bit}"
    self.class.where(id:).update_all("#{sql}, updated_at = #{self.class.connection.quote(Time.current)}")
    self.partially_successful = partial
  end

  # Called from Purchase when a purchase transitions to a successful state. The
  # `after_save` hook above never fires for real checkouts because the order row is
  # saved once at creation, while its purchases are still in progress — purchases
  # only succeed a few seconds later, without touching the order row again. This
  # entry point lets the purchase-success path schedule the reminder.
  def schedule_review_reminder
    schedule_review_reminder! if should_schedule_review_reminder?
  end

  def schedule_review_reminder!
    OrderReviewReminderJob.perform_in(reminder_email_delay, id)
    update!(review_reminder_scheduled_at: Time.current)
  end

  private
    # Currently, there is some order-level data that is duplicated on individual purchase records
    # For example, payment information is duplicated on each purchase that requires payment.
    # Since the data is identical, we can just use one of the purchases as the source of that data.
    # Ideally, the data should be saved directly on the order.
    # If at least one product requires payment, then the order requires payment.
    def purchase_with_payment_as_orderable
      @_purchase_with_payment_as_orderable = successful_purchases.non_free.first || purchase_as_orderable
    end

    # To be used only when the data retrieved is present on ALL purchases.
    def purchase_as_orderable
      @_purchase_as_orderable = successful_purchases.first
    end

    def successful_purchases
      purchases.all_success_states_including_test
    end

    def should_schedule_review_reminder?
      # Gift-sender purchases are never review-eligible themselves, but the gift
      # recipient's linked purchase is — resolve each purchase through
      # `purchase_for_review_reminder` so a fully-gifted order still schedules a
      # reminder (for the recipient) instead of silently sending none.
      review_reminder_scheduled_at.nil? && cart.present? &&
        purchases.any? { _1.purchase_for_review_reminder&.eligible_for_review_reminder? }
    end

    def reminder_email_delay
      return ProductReview::REVIEW_REMINDER_PHYSICAL_DELAY if purchases.all? { _1.link.require_shipping }
      ProductReview::REVIEW_REMINDER_DELAY
    end
end
