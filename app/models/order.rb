# frozen_string_literal: true

class Order < ApplicationRecord
  include ExternalId, Orderable, FlagShihTzu

  belongs_to :purchaser, class_name: "User", optional: true
  has_many :order_purchases, dependent: :destroy
  has_many :purchases, through: :order_purchases, dependent: :destroy

  has_many :charges, dependent: :destroy
  has_one :cart, dependent: :destroy

  attr_accessor :setup_future_charges

  has_flags 1 => :DEPRECATED_seller_receipt_enabled,
            column: "flags",
            flag_query_mode: :bit_operator,
            check_for_column: false

  delegate :card_type, :card_visual, :full_name, to: :purchase_with_payment_as_orderable

  after_save :schedule_review_reminder!, if: :should_schedule_review_reminder?

  def receipt_for_gift_receiver?
    # Ref https://gumroad.slack.com/archives/C01DBV0A257/p1702993001755659?thread_ts=1702968729.055289&cid=C01DBV0A257
    # Raise to document the current state so that the caller is aware, rather than returning a Boolean that can
    # generate undesired results.
    raise NotImplementedError, "Not supported for multi-item orders" if successful_purchases.count > 1

    purchase_as_orderable.is_gift_receiver_purchase?
  end

  def receipt_for_gift_sender?
    # Ref https://gumroad.slack.com/archives/C01DBV0A257/p1702993001755659?thread_ts=1702968729.055289&cid=C01DBV0A257
    # Raise to document the current state so that the caller is aware, rather than returning a Boolean that can
    # generate undesired results.
    raise NotImplementedError, "Not supported for multi-item orders" if successful_purchases.count > 1

    purchase_as_orderable.is_gift_sender_purchase?
  end

  def email
    purchase_as_orderable.email
  end

  def locale
    purchase_as_orderable.locale
  end

  def test?
    purchase_as_orderable.is_test_purchase?
  end

  def send_charge_receipts
    return unless uses_charge_receipt?

    successful_charges.each do
      SendChargeReceiptJob.set(queue: _1.purchases_requiring_stamping.any? ? "default" : "critical").perform_async(_1.id)
    end
  end

  def successful_charges
    @_successful_charges ||= charges.select { _1.successful_purchases.any? }
  end

  def unsubscribe_buyer
    purchase_as_orderable.unsubscribe_buyer
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
      review_reminder_scheduled_at.nil? && cart.present? && purchases.any?(&:eligible_for_review_reminder?)
    end

    def reminder_email_delay
      return ProductReview::REVIEW_REMINDER_PHYSICAL_DELAY if purchases.all? { _1.link.require_shipping }
      ProductReview::REVIEW_REMINDER_DELAY
    end
end
