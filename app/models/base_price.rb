# frozen_string_literal: true

class BasePrice < ApplicationRecord
  has_paper_trail

  self.table_name = "prices"

  include BasePrice::Recurrence
  include ExternalId
  include ProductsHelper
  include Deletable
  include FlagShihTzu

  validates :price_cents, :currency, presence: true
  validates :fixed_duration_months,
    numericality: { greater_than: 0, only_integer: true }, allow_nil: true
  validate :fixed_duration_must_be_multiple_of_recurrence_period

  has_flags 1 => :is_rental,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  scope :is_buy, -> { self.not_is_rental }
  scope :with_fixed_duration, -> { where.not(fixed_duration_months: nil) }
  scope :without_fixed_duration, -> { where(fixed_duration_months: nil) }

  def is_buy?
    !is_rental?
  end

  def is_default_recurrence?
    recurrence == link.subscription_duration.to_s
  end

  def has_fixed_duration?
    fixed_duration_months.present?
  end

  def charge_occurrence_count
    return nil if !has_fixed_duration? || !recurrence.present?

    months_per_cycle = BasePrice::Recurrence.number_of_months_in_recurrence(recurrence)
    return nil if !months_per_cycle

    # Use integer division with ceiling behavior to avoid float rounding errors
    (fixed_duration_months + months_per_cycle - 1) / months_per_cycle
  end

  def duration_display
    if fixed_duration_months
      unit = fixed_duration_months == 1 ? "month" : "months"
      return "#{fixed_duration_months} #{unit}"
    end
    "Ongoing"
  end

  def formatted_duration_with_recurrence
    return duration_display unless has_fixed_duration?

    occurrence_count = charge_occurrence_count
    return duration_display unless occurrence_count

    case recurrence
    when "monthly"
      "#{occurrence_count} #{occurrence_count == 1 ? 'month' : 'months'}"
    when "quarterly"
      "#{occurrence_count} #{occurrence_count == 1 ? 'quarter' : 'quarters'}"
    when "biannually"
      "#{occurrence_count} #{occurrence_count == 1 ? 'payment' : 'payments'} (6 months each)"
    when "yearly"
      "#{occurrence_count} #{occurrence_count == 1 ? 'year' : 'years'}"
    when "every_two_years"
      "#{occurrence_count} #{occurrence_count == 1 ? 'payment' : 'payments'} (2 years each)"
    else
      duration_display
    end
  end

  private

  def fixed_duration_must_be_multiple_of_recurrence_period
    return if fixed_duration_months.nil? || recurrence.blank?

    period_months = BasePrice::Recurrence.number_of_months_in_recurrence(recurrence)
    return unless period_months

    if fixed_duration_months % period_months != 0
      errors.add(:fixed_duration_months, "must be a multiple of the recurrence period (#{period_months} months)")
    end
  end
end
