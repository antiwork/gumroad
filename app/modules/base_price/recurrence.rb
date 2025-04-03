# frozen_string_literal: true

module BasePrice::Recurrence
  MONTHLY = "monthly"
  QUARTERLY = "quarterly"
  BIANNUALLY = "biannually"
  YEARLY = "yearly"
  EVERY_TWO_YEARS = "every_two_years"

  DEFAULT_TIERED_MEMBERSHIP_RECURRENCE = MONTHLY

  ALLOWED_RECURRENCES = [
    MONTHLY,
    QUARTERLY,
    BIANNUALLY,
    YEARLY,
    EVERY_TWO_YEARS
  ].freeze

  ALLOWED_INSTALLMENT_PLAN_RECURRENCES = [
    MONTHLY,
  ].freeze

  RECURRENCE_TO_NUMBER_OF_MONTHS = {
    MONTHLY => 1,
    QUARTERLY => 3,
    BIANNUALLY => 6,
    YEARLY => 12,
    EVERY_TWO_YEARS => 24
  }.freeze

  RECURRENCE_TO_RENEWAL_REMINDER_EMAIL_DAYS = {
    MONTHLY => 1.day,
    QUARTERLY => 7.days,
    BIANNUALLY => 7.days,
    YEARLY => 7.days,
    EVERY_TWO_YEARS => 7.days
  }.freeze

  PERMITTED_PARAMS = ALLOWED_RECURRENCES.inject({}) do |c, recurrence|
    # TODO: :product_edit_react cleanup
    c.merge!(recurrence.to_sym => [:enabled, :price, :price_cents, :suggested_price, :suggested_price_cents])
  end.freeze

  def self.all
    ALLOWED_RECURRENCES
  end

  def self.number_of_months_in_recurrence(recurrence)
    RECURRENCE_TO_NUMBER_OF_MONTHS[recurrence]
  end

  def self.renewal_reminder_email_days(recurrence)
    RECURRENCE_TO_RENEWAL_REMINDER_EMAIL_DAYS[recurrence]
  end

  def self.seconds_in_recurrence(recurrence)
    number_of_months = BasePrice::Recurrence.number_of_months_in_recurrence(recurrence)
    number_of_months.months
  end

  def recurrence_long_indicator(recurrence)
    case recurrence
    when BasePrice::Recurrence::MONTHLY
      "a month"
    when BasePrice::Recurrence::QUARTERLY
      "every 3 months"
    when BasePrice::Recurrence::BIANNUALLY
      "every 6 months"
    when BasePrice::Recurrence::YEARLY
      "a year"
    when BasePrice::Recurrence::EVERY_TWO_YEARS
      "every 2 years"
    end
  end

  def recurrence_short_indicator(recurrence)
    case recurrence
    when MONTHLY then "/ month"
    when QUARTERLY then "/ 3 months"
    when BIANNUALLY then "/ 6 months"
    when YEARLY then "/ year"
    when EVERY_TWO_YEARS then "/ 2 years"
    end
  end

  def single_period_indicator(recurrence)
    case recurrence
    when "monthly" then "1-month"
    when "yearly" then "1-year"
    when "quarterly" then "3-month"
    when "biannually" then "6-month"
    when "every_two_years" then "2-year"
    end
  end
end
