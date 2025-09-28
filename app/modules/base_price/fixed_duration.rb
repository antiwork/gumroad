# frozen_string_literal: true

module BasePrice::FixedDuration
  extend ActiveSupport::Concern

  included do
    validate :fixed_duration_must_be_multiple_of_recurrence_period
  end

  def charge_occurrence_count
    return nil if !fixed_duration_months? || !recurrence.present?

    months_per_cycle = number_of_months_in_recurrence(recurrence)
    return nil if !months_per_cycle

    (fixed_duration_months + months_per_cycle - 1) / months_per_cycle
  end

  def duration_display
    fixed_duration_months? ? "#{fixed_duration_months} #{'month'.pluralize(fixed_duration_months)}" : "Ongoing"
  end

  def formatted_duration_with_recurrence
    return duration_display unless fixed_duration_months?

    occurrence_count = charge_occurrence_count
    return duration_display unless occurrence_count

    case recurrence
    when BasePrice::Recurrence::MONTHLY
      unit = "month"
      return "#{occurrence_count} #{unit.pluralize(occurrence_count)}"
    when BasePrice::Recurrence::QUARTERLY
      unit = "quarter"
      return "#{occurrence_count} #{unit.pluralize(occurrence_count)}"
    when BasePrice::Recurrence::YEARLY
      unit = "year"
      return "#{occurrence_count} #{unit.pluralize(occurrence_count)}"
    when BasePrice::Recurrence::BIANNUALLY, BasePrice::Recurrence::EVERY_TWO_YEARS
      payments_label = "payment".pluralize(occurrence_count)
      months_per_cycle = number_of_months_in_recurrence(recurrence)
      interval_label = if months_per_cycle % 12 == 0
        years = months_per_cycle / 12
        "#{years} #{"year".pluralize(years)} each"
      else
        "#{months_per_cycle} #{"month".pluralize(months_per_cycle)} each"
      end
      return "#{occurrence_count} #{payments_label} (#{interval_label})"
    else
      return duration_display
    end
  end

  def fixed_duration_pricing_label
    return nil unless fixed_duration_months?

    months = fixed_duration_months
    return "1-month plan at" if months == 1
    return "#{months}-month plan at" if months < 12
    return "1-year plan at" if months == 12
    return "#{months / 12}-year plan at" if (months % 12).zero?
    "#{months}-month plan at"
  end


  private
    def fixed_duration_must_be_multiple_of_recurrence_period
      return if fixed_duration_months.nil? || recurrence.blank?

      period_months = number_of_months_in_recurrence(recurrence)
      return unless period_months

      unless fixed_duration_months.multiple_of?(period_months)
        errors.add(:fixed_duration_months, "must be a multiple of the recurrence period (#{period_months} months)")
      end
    end
end


