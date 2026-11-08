# frozen_string_literal: true

# One row per checkout-time chargeback-ring evaluation that reached the volume floor
# (paid_sales >= Purchase::ChargebackRingSignal::MIN_PAID_SALES), blocked or allowed, plus a row
# for every evaluation that raised (decision "error"). Both sides are recorded so the signal's
# precision is measurable in SQL:
#
#   SELECT decision, COUNT(*) FROM chargeback_ring_signals
#   WHERE created_at >= NOW() - INTERVAL 30 DAY GROUP BY decision;
#
# Pure telemetry: nothing reads this table on the purchase path.
class ChargebackRingSignal < ApplicationRecord
  belongs_to :seller, class_name: "User"
  belongs_to :purchase

  validates :decision, presence: true, inclusion: { in: [
    Purchase::ChargebackRingSignal::DECISION_BLOCKED,
    Purchase::ChargebackRingSignal::DECISION_ALLOWED,
    Purchase::ChargebackRingSignal::DECISION_ERROR,
  ] }
end
