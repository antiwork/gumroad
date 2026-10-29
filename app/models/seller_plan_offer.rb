# frozen_string_literal: true

# One row per seller who reaches the paid-publish experiment, and the whole funnel for that seller:
# `offered` when the publish gate stops them, `checkout_started` when they open Stripe Checkout,
# `active`/`past_due`/`canceled` from the platform-account subscription webhook.
class SellerPlanOffer < ApplicationRecord
  ARMS = %w[five ten].freeze
  STATUSES = %w[offered checkout_started active past_due canceled].freeze

  belongs_to :user
  belongs_to :link, optional: true

  validates :arm, inclusion: { in: ARMS }
  validates :price_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :status, inclusion: { in: STATUSES }

  scope :with_active_plan, -> { where(status: "active") }

  def active?
    status == "active"
  end

  # Idempotent: a seller keeps the row (and the arm) they were first offered, so re-offering after a
  # cancellation reuses the same price instead of reshuffling them between arms mid-experiment.
  def self.record_offer!(user:, link:, arm:, price_cents:)
    find_or_create_by!(user_id: user.id) do |offer|
      offer.link_id = link.id
      offer.arm = arm
      offer.price_cents = price_cents
      offer.status = "offered"
      offer.offered_at = Time.current
    end
  end
end
