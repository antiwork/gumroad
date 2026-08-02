# frozen_string_literal: true

# Represents a user-initiated plan change to a subscription, for example to
# upgrade or downgrade their tier or recurrence. Used by `RecurringChargeWorker`
# worker to check if a user has a plan change that must be made at the end of
# the current billing period, before initiating the next recurring charge.
class SubscriptionPlanChange < ApplicationRecord
  # Must exceed the longest single gap in SendMembershipPriceUpdateEmailJob's retry ladder
  # (~2.1h before the 9th attempt), or the scheduler steals the claim from a job that is still
  # retrying and a second delivery job sends a duplicate notice. Spec pins the relationship.
  PRICE_CHANGE_NOTIFICATION_CLAIM_TTL = 3.hours

  has_paper_trail

  include Deletable
  include CurrencyHelper
  include FlagShihTzu

  belongs_to :subscription
  belongs_to :tier, class_name: "BaseVariant", foreign_key: "base_variant_id", optional: true

  has_flags 1 => :for_product_price_change,
            2 => :applied,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  validates :recurrence, presence: true
  validates :tier, presence: true, if: -> { subscription&.link&.is_tiered_membership? }
  validates :recurrence, inclusion: { in: BasePrice::Recurrence::ALLOWED_RECURRENCES }
  validates :perceived_price_cents, presence: true

  scope :applicable_for_product_price_change_as_of, ->(date) {
    alive.not_applied
      .for_product_price_change
      .where("effective_on <= ?", date)
  }

  scope :currently_applicable, -> {
    for_price_change =
      SubscriptionPlanChange.alive.not_applied
        .applicable_for_product_price_change_as_of(Date.today)
        .where.not(notified_subscriber_at: nil)
    not_for_price_change = SubscriptionPlanChange.alive.not_applied.not_for_product_price_change

    subquery_sqls = [for_price_change, not_for_price_change].map(&:to_sql)
    from("(" + subquery_sqls.join(" UNION ") + ") AS #{table_name}")
  }

  def claim_price_change_notification
    with_lock do
      next if notified_subscriber_at.present?
      next if notification_claim_id.present? &&
        notification_claimed_at.present? &&
        notification_claimed_at > PRICE_CHANGE_NOTIFICATION_CLAIM_TTL.ago

      claim_id = SecureRandom.uuid
      update_columns(notification_claim_id: claim_id, notification_claimed_at: Time.current)
      claim_id
    end
  end

  def release_price_change_notification_claim(claim_id)
    with_lock do
      next unless notification_claim_id == claim_id
      next if notified_subscriber_at.present?

      update_columns(notification_claim_id: nil, notification_claimed_at: nil)
    end
  end

  def start_price_change_notification_delivery(claim_id)
    with_lock do
      next false if notified_subscriber_at.present? || notification_claim_id != claim_id

      update_columns(notification_claimed_at: Time.current)
      true
    end
  end

  def price_change_notification_recipient_eligible?
    subscription.alive? && !subscription.pending_cancellation?
  end

  # Takes the subscription row lock that `Subscription#cancel!` takes, so a cancellation either
  # commits before this reads it (claim released, marker stays nil) or after the marker is written
  # (the notice genuinely preceded the cancellation). Without that ordering a cancellation landing
  # during delivery would leave the increase pre-authorized for a later restart, which keeps the
  # plan change alive whenever the restart is on the same plan and price.
  def confirm_price_change_notification(claim_id)
    subscription.with_lock do
      recipient_eligible = price_change_notification_recipient_eligible?

      with_lock do
        next false if notified_subscriber_at.present? || notification_claim_id != claim_id

        unless recipient_eligible
          update_columns(notification_claim_id: nil, notification_claimed_at: nil)
          next false
        end

        assign_attributes(
          notification_claim_id: nil,
          notification_claimed_at: nil,
          notified_subscriber_at: Time.current,
        )
        # Runs after the mail provider has already accepted the message, so a validation failure
        # here (a legacy row missing its tier) would leave the notice sent and the marker unset,
        # and every later run would send it again. Skip validations, keep the paper_trail version.
        save!(validate: false)
        true
      end
    end
  end

  def formatted_display_price
    formatted_price_in_currency_with_recurrence(
      perceived_price_cents,
      subscription.link.price_currency_type,
      recurrence,
      subscription.charge_occurrence_count
    )
  end
end
