# frozen_string_literal: true

module InstallmentRuleHelper
  # Converts duration and period into seconds
  #
  # Examples
  #   convert_to_seconds(1, "HOUR")
  #   #=> 3600
  #   convert_to_seconds(7, "DAY")
  #   # => 604800
  #
  # Returns an integer
  def convert_to_seconds(duration, period)
    duration = duration.to_i
    case period
    when InstallmentRule::HOUR
      duration * 1.hour
    when InstallmentRule::DAY
      duration * 1.day
    when InstallmentRule::WEEK
      duration * 1.week
    when InstallmentRule::MONTH
      duration * 1.month
    end
  end
end
