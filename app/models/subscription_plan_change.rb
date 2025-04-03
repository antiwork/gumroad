# frozen_string_literal: true

# Represents a user-initiated plan change to a subscription, for example to
# upgrade or downgrade their tier or recurrence. Used by `RecurringChargeWorker`
# worker to check if a user has a plan change that must be made at the end of
# the current billing period, before initiating the next recurring charge.
class SubscriptionPlanChange < ApplicationRecord
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

  def formatted_display_price
    formatted_price_in_currency_with_recurrence(
      perceived_price_cents,
      subscription.link.price_currency_type,
      recurrence,
      subscription.charge_occurrence_count
    )
  end
end
