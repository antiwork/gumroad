# frozen_string_literal: true

class Workflow < ApplicationRecord
  has_paper_trail

  include ActionView::Helpers::NumberHelper, ExternalId, Deletable, JsonData, WithFiltering, FlagShihTzu,
          Workflow::AbandonedCartProducts

  has_flags 1 => :send_to_past_customers,
            column: "flags",
            flag_query_mode: :bit_operator,
            check_for_column: false

  belongs_to :link, optional: true
  belongs_to :seller, class_name: "User", optional: true
  belongs_to :base_variant, optional: true
  has_many :installments
  has_many :alive_installments, -> { alive }, class_name: "Installment"

  attr_json_data_accessor :workflow_trigger

  validates_presence_of :seller

  MEMBER_CANCELLATION_WORKFLOW_TRIGGER = "member_cancellation"
  SAVE_ACTION = "save"
  SAVE_AND_PUBLISH_ACTION = "save_and_publish"
  SAVE_AND_UNPUBLISH_ACTION = "save_and_unpublish"

  scope :published, -> { where.not(published_at: nil) }

  def recipient_type_audience?
    audience_type?
  end

  def applies_to_purchase?(purchase)
    return false if product_type? && link_id != purchase.link_id
    return false if variant_type? && !purchase.variant_attributes.include?(base_variant)
    purchase_passes_filters(purchase)
  end

  def new_customer_trigger?
    workflow_trigger.nil?
  end

  def member_cancellation_trigger?
    workflow_trigger == MEMBER_CANCELLATION_WORKFLOW_TRIGGER
  end

  def targets_variant?(variant)
    (variant_type? && base_variant_id == variant.id) || (bought_variants.present? && bought_variants.include?(variant.external_id))
  end

  def mark_deleted!
    self.deleted_at = Time.current
    installments.each do |installment|
      installment.mark_deleted!
      installment.installment_rule.mark_deleted!
    end
    save!
  end

  def publish!
    return true if published_at.present?

    if !abandoned_cart_type? && !seller.eligible_to_send_emails?
      errors.add(:base, "You cannot publish a workflow until you have made at least #{Money.from_cents(Installment::MINIMUM_SALES_CENTS_VALUE).format(no_cents: true)} in total earnings and received a payout")
      raise ActiveRecord::RecordInvalid.new(self)
    end

    self.published_at = DateTime.current
    self.first_published_at ||= published_at
    installments.alive.find_each do |installment|
      installment.publish!(published_at:)
      schedule_installment(installment)
    end
    save!
  end

  def unpublish!
    return true if published_at.nil?

    self.published_at = nil
    installments.alive.find_each(&:unpublish!)
    save!
  end

  def has_never_been_published?
    first_published_at.nil?
  end

  def schedule_installment(installment, old_delayed_delivery_time: nil)
    return if installment.abandoned_cart_type?
    return unless alive?
    return unless new_customer_trigger?
    return unless installment.published?
    # don't schedule the installment if it is only for new customers/followers and it hasn't been scheduled before (old_delayed_delivery_time is nil)
    return if old_delayed_delivery_time.nil? && installment.is_for_new_customers_of_workflow

    # earliest_valid_time is:
    #   `installment.published_at` if the installment is for new customers only
    #   `nil` if the installment is being published for the first time and is not for new customers only,
    #   the time based off old_delayed_delivery_time if the installment has already been published before (at least once).
    # We only want the purchases and/or followers created after earliest_valid_time because the specified
    # installment has not been delivered to them and needs to be (re-)scheduled.
    earliest_valid_time = if old_delayed_delivery_time.nil?
      nil
    elsif installment.is_for_new_customers_of_workflow && installment.published_at >= old_delayed_delivery_time.seconds.ago
      installment.published_at
    else
      old_delayed_delivery_time.seconds.ago
    end

    SendWorkflowPostEmailsJob.perform_async(installment.id, earliest_valid_time&.iso8601)
  end
end
