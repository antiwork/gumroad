# frozen_string_literal: true

class BlackRecurringService < RecurringService
  SERVICE_DESCRIPTION = "Gumroad Premium"

  attr_json_data_accessor :change_recurrence_to
  attr_json_data_accessor :invite_credit

  # black recurring service state transitions:
  #
  #                   →  pending_cancellation  →  cancelled
  #                 ↑         ↓                    ↓
  # inactive  →  active      ←          ←         ←
  #                 ↓         ↑                    ↑
  #                   →  pending_failure    →    failed
  #
  state_machine :state, initial: :inactive do
    event :mark_active do
      transition any => :active
    end

    event :mark_active_from_pending_cancellation do
      transition pending_cancellation: :active
    end

    event :mark_pending_cancellation do
      transition %i[active pending_failure] => :pending_cancellation
    end

    event :mark_cancelled do
      transition pending_cancellation: :cancelled
    end

    event :mark_cancelled_immediately do
      transition %i[active pending_cancellation pending_failure] => :cancelled
    end

    event :mark_pending_failure do
      transition active: :pending_failure
    end

    event :mark_failed do
      transition pending_failure: :failed
    end
  end

  scope :active,                                -> { where(state: "active") }
  scope :active_including_pending_cancellation, -> { where("state = 'active' or state = 'pending_cancellation'") }

  def is_active?
    active? || pending_cancellation? || pending_failure?
  end

  def service_description
    SERVICE_DESCRIPTION
  end

  def discount_code
    return unless invite_credit.present? && invite_credit > 0

    self.invite_credit -= 1
    save!
    INVITE_CREDIT_DISCOUNT_CODE
  end

  def invite_discount_amount
    return price_cents if recurrence == "monthly" && price_cents > 0

    monthly_tier_amount_cents(user.distinct_paid_customers_count_last_year)
  end
end
