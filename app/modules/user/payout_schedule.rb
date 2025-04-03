# frozen_string_literal: true

module User::PayoutSchedule
  PAYOUT_STARTING_DATE = Date.new(2012, 12, 21)
  PAYOUT_RECURRENCE_DAYS = 7
  PAYOUT_DELAY_DAYS = 7

  WEEKLY = "weekly"
  MONTHLY = "monthly"
  QUARTERLY = "quarterly"

  include CurrencyHelper

  def next_payout_date
    return nil if unpaid_balance_cents < minimum_payout_amount_cents

    upcoming_payout_date = get_initial_payout_date(Date.today)

    until upcoming_payout_date >= Date.today
      upcoming_payout_date = advance_payout_date(upcoming_payout_date)
    end

    if payout_amount_for_payout_date(upcoming_payout_date) < minimum_payout_amount_cents
      upcoming_payout_date = advance_payout_date(upcoming_payout_date)
    end

    if upcoming_payout_date == Date.today && payments.where("date(created_at) = ?", Date.today).first.present?
      upcoming_payout_date = advance_payout_date(upcoming_payout_date)
    end

    upcoming_payout_date
  end

  def payout_amount_for_payout_date(payout_date)
    unpaid_balance_cents_up_to_date(payout_date - PAYOUT_DELAY_DAYS)
  end

  def formatted_balance_for_next_payout_date
    next_payout_date = self.next_payout_date
    return if next_payout_date.nil?

    payout_amount_cents = payout_amount_for_payout_date(next_payout_date)
    formatted_dollar_amount(payout_amount_cents)
  end

  # Public: Returns the upcoming payout date, not taking a user into account.
  def self.next_scheduled_payout_date
    scheduled_payout_date = PAYOUT_STARTING_DATE
    scheduled_payout_date += PAYOUT_RECURRENCE_DAYS while scheduled_payout_date < Date.today
    scheduled_payout_date
  end

  # Public: Returns the upcoming payout's end date, not taking a user into account.
  def self.next_scheduled_payout_end_date
    next_scheduled_payout_date - PAYOUT_DELAY_DAYS
  end

  def self.manual_payout_end_date
    if [2, 3, 4, 5].include?(Date.today.wday) # Tuesday to Friday
      next_scheduled_payout_end_date
    else
      next_scheduled_payout_end_date - PAYOUT_DELAY_DAYS
    end
  end

  private
    def last_friday_of_week(date)
      return date if date.friday?
      date.next_occurring(:friday)
    end

    def last_friday_of_month(date)
      month_end = date.end_of_month
      month_end.friday? ? month_end : month_end.prev_occurring(:friday)
    end

    def last_friday_of_quarter(date)
      quarter_end = date.end_of_quarter
      quarter_end.friday? ? quarter_end : quarter_end.prev_occurring(:friday)
    end

    def get_initial_payout_date(date)
      case payout_frequency
      when WEEKLY then last_friday_of_week(date)
      when MONTHLY then last_friday_of_month(date)
      when QUARTERLY then last_friday_of_quarter(date)
      end
    end

    def advance_payout_date(date)
      case payout_frequency
      when WEEKLY then last_friday_of_week(date.next_day(7))
      when MONTHLY then last_friday_of_month(date.next_month)
      when QUARTERLY then last_friday_of_quarter(date.next_month(3))
      end
    end
end
