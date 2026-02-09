# frozen_string_literal: true

module User::PayoutSchedule
  PAYOUT_STARTING_DATE = Date.new(2012, 12, 21)
  PAYOUT_RECURRENCE_DAYS = 7
  PAYOUT_DELAY_DAYS = 7

  WEEKLY = "weekly"
  MONTHLY = "monthly"
  QUARTERLY = "quarterly"
  DAILY = "daily"

  include CurrencyHelper

  def next_payout_date
    return nil if unpaid_balance_cents < minimum_payout_amount_cents

    return Date.current + 1 if payout_frequency == DAILY && Payouts.is_user_payable(self, Date.current, payout_type: Payouts::PAYOUT_TYPE_INSTANT)

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

  def current_payout_processor
    if (paypal_payout_email.present? && active_bank_account.blank?) || !native_payouts_supported?
      PayoutProcessorType::PAYPAL
    else
      PayoutProcessorType::STRIPE
    end
  end

  def upcoming_payouts
    upcoming_payout_date = next_payout_date
    upcoming_payouts = []

    while upcoming_payout_date
      payout_amount = payout_amount_for_payout_date(upcoming_payout_date) - upcoming_payouts.sum(&:amount_cents)
      break if payout_amount < minimum_payout_amount_cents

      payout_period_end_date = payout_period_end_date_for_payout_date(upcoming_payout_date)
      payout_balances = unpaid_balances_up_to_date(payout_period_end_date)
      payout_balances -= unpaid_balances_up_to_date(upcoming_payouts.last.payout_period_end_date) if upcoming_payouts.present?

      upcoming_payout = Payment.new(
        user: self,
        amount_cents: payout_amount,
        payout_period_end_date:,
        currency: Currency::USD,
        state: payouts_status,
        created_at: upcoming_payout_date,
        processor: current_payout_processor,
        bank_account: (active_bank_account if current_payout_processor == PayoutProcessorType::STRIPE),
        payment_address: (paypal_payout_email if current_payout_processor == PayoutProcessorType::PAYPAL),
        )
      upcoming_payout.balances = payout_balances

      upcoming_payouts << upcoming_payout

      upcoming_payout_date = advance_payout_date(upcoming_payout_date)
    end

    upcoming_payouts
  end

  def payout_amount_for_payout_date(payout_date)
    if payout_frequency == DAILY && Payouts.is_user_payable(self, payout_date - 1, payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      instantly_payable_unpaid_balance_cents_up_to_date(payout_date - 1)
    else
      unpaid_balance_cents_up_to_date(payout_date - PAYOUT_DELAY_DAYS)
    end
  end

  def payout_period_end_date_for_payout_date(payout_date)
    if payout_frequency == DAILY && Payouts.is_user_payable(self, payout_date - 1, payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      payout_date - 1
    else
      payout_date - PAYOUT_DELAY_DAYS
    end
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
      # Daily payouts are handled separately, so this date is a fallback, for any amount not able to be paid instantly
      when DAILY then last_friday_of_week(date)
      when WEEKLY then last_friday_of_week(date)
      when MONTHLY then last_friday_of_month(date)
      when QUARTERLY then last_friday_of_quarter(date)
      end
    end

    def advance_payout_date(date)
      case payout_frequency
      # Daily payouts are handled separately, so this date is a fallback, for any amount not able to be paid instantly
      when DAILY then last_friday_of_week(date.next_day(7))
      when WEEKLY then last_friday_of_week(date.next_day(7))
      when MONTHLY then last_friday_of_month(date.next_month)
      when QUARTERLY then last_friday_of_quarter(date.next_month(3))
      end
    end
end
