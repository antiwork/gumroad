# frozen_string_literal: true

class CallLimitationInfo < ApplicationRecord
  DEFAULT_MINIMUM_NOTICE_IN_MINUTES = 180
  CHECKOUT_GRACE_PERIOD = 3.minutes

  belongs_to :call, class_name: "Link"

  validate :belongs_to_call

  attribute :minimum_notice_in_minutes, default: DEFAULT_MINIMUM_NOTICE_IN_MINUTES

  def allows?(start_time)
    has_enough_notice?(start_time) && can_take_more_calls_on?(start_time)
  end

  def has_enough_notice?(start_time)
    return false if start_time.past?
    return true if minimum_notice_in_minutes.nil?

    start_time >= minimum_notice_in_minutes.minutes.from_now - CHECKOUT_GRACE_PERIOD
  end

  def can_take_more_calls_on?(start_time)
    return true if maximum_calls_per_day.nil?
    call.sold_calls.starts_on_date(start_time, call.user.timezone).count < maximum_calls_per_day
  end

  private
    def belongs_to_call
      if call.native_type != Link::NATIVE_TYPE_CALL
        errors.add(:base, "Cannot create call limitations for a non-call product.")
      end
    end
end
