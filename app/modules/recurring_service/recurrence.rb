# frozen_string_literal: true

module RecurringService::Recurrence
  def recurrence_indicator
    {
      monthly: " a month",
      yearly: " a year"
    }[recurrence.to_sym]
  end

  def recurrence_duration
    {
      monthly: 1.month,
      yearly: 1.year
    }[recurrence.to_sym]
  end
end
