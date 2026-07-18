# frozen_string_literal: true

FactoryBot.define do
  factory :failed_refund_exception do
    refund
    owner { FailedRefundException.default_owner }
    notification_room { FailedRefundException.default_notification_room(owner:) }
    state { "pending" }
    due_at { FailedRefundException.response_sla.from_now }
    balance_reversed { false }
  end
end
