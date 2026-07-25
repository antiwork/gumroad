# frozen_string_literal: true

module User::PayoutSchedule
  PAYOUT_DELAY_DAYS = 7

  WEEKLY = "weekly"
  MONTHLY = "monthly"
  QUARTERLY = "quarterly"
  DAILY = "daily"

  include CurrencyHelper

  # Weekday the seller's own payout rail actually runs on. Payouts are split across several
  # jobs that each fire on a different weekday and each cover a different set of sellers
  # (see PayoutRailSchedule), so a Philippine bank account is paid on Tuesday, a UK one on
  # Wednesday, a US one on Thursday, PayPal on Friday.
  def payout_weekday
    # A bank account decides the rail on its own: the per-weekday payout jobs select sellers by
    # their BankAccount row's type, and a seller who has given us a bank account is never paid
    # via PayPal (PaypalPayoutProcessor refuses outright when active_bank_account is present).
    bank_account = active_bank_account
    return PayoutRailSchedule.weekday_for_bank_account_type(bank_account.type) if bank_account.present?

    return PayoutRailSchedule.paypal_weekday if current_payout_processor == PayoutProcessorType::PAYPAL

    # A Stripe payout with no bank account goes out through the seller's own connected Stripe
    # account, which is paid by its own run.
    PayoutRailSchedule.stripe_connect_weekday
  end

  def next_payout_date
    return nil if unpaid_balance_cents < minimum_payout_amount_cents

    return Date.current + 1 if payout_frequency == DAILY && Payouts.is_user_payable(self, Date.current, payout_type: Payouts::PAYOUT_TYPE_INSTANT)

    # The payout CYCLE is still anchored on the platform's Friday-to-Friday week (that is
    # what decides which balances are included), but the day the seller is actually paid is
    # their rail's weekday inside that cycle — so the cycle math below stays on Fridays and
    # only the date we hand back is converted.
    payout_cycle_date = get_initial_payout_date(Date.today)

    until payout_date_for_cycle(payout_cycle_date) >= Date.today
      payout_cycle_date = advance_payout_date(payout_cycle_date)
    end

    if payout_amount_for_cycle(payout_cycle_date) < minimum_payout_amount_cents
      payout_cycle_date = advance_payout_date(payout_cycle_date)
    end

    upcoming_payout_date = payout_date_for_cycle(payout_cycle_date)

    if upcoming_payout_date == Date.today && payments.where("date(created_at) = ?", Date.today).first.present?
      upcoming_payout_date = payout_date_for_cycle(advance_payout_date(payout_cycle_date))
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

      upcoming_payout_date = payout_date_for_cycle(advance_payout_date(payout_cycle_for_payout_date(upcoming_payout_date)))
    end

    upcoming_payouts
  end

  def payout_amount_for_payout_date(payout_date)
    if payout_frequency == DAILY && Payouts.is_user_payable(self, payout_date - 1, payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      instantly_payable_unpaid_balance_cents_up_to_date(payout_date - 1)
    else
      unpaid_balance_cents_up_to_date(payout_period_end_date_for_payout_date(payout_date))
    end
  end

  def payout_period_end_date_for_payout_date(payout_date)
    if payout_frequency == DAILY && Payouts.is_user_payable(self, payout_date - 1, payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      payout_date - 1
    else
      # Which balances a payout covers is decided by the platform's Friday cycle, not by the
      # weekday the seller's rail happens to run on: the payout jobs all pay balances up to
      # User::PayoutSchedule.next_scheduled_payout_end_date, whichever weekday they fire. So
      # a Tuesday-rail seller paid on July 28 is paid for balances up to July 24, the same as
      # a Friday-rail seller paid on July 31 — anchor on the cycle, not on the payout date.
      payout_cycle_for_payout_date(payout_date) - PAYOUT_DELAY_DAYS
    end
  end

  def formatted_balance_for_next_payout_date
    next_payout_date = self.next_payout_date
    return if next_payout_date.nil?

    payout_amount_cents = payout_amount_for_payout_date(next_payout_date)
    formatted_dollar_amount(payout_amount_cents)
  end

  # Public: Returns the upcoming payout date, not taking a user into account.
  #
  # This is the platform's payout RUN date — the Friday the payout job fires — and it is
  # deliberately seller-agnostic. An individual seller can be on a daily, weekly, monthly,
  # or quarterly frequency, so anything a seller sees must come from the per-seller
  # #next_payout_date above (which branches on payout_frequency), never from here. The
  # weekly run only actually pays a seller whose own next payout date has come up; see the
  # per-user check in Payouts.
  #
  # Scheduled payouts run every Friday, so this is simply the next Friday (today, if
  # today is a Friday). It used to be computed by starting at a hardcoded 2012 date and
  # stepping forward a week at a time until the result caught up to today, which meant
  # every call looped ~700 times and grew by one iteration a week forever. The anchor
  # date carried no meaning beyond "a Friday", so anchoring to the current week instead
  # gives the same answer in constant time and can't drift.
  def self.next_scheduled_payout_date
    today = Date.today
    today.friday? ? today : today.next_occurring(:friday)
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
    # The seller-facing payout date for a payout cycle. Cycle dates are always Fridays (the
    # platform's payout week), and each rail's job fires earlier in that same week — Tuesday
    # for cross-border banks, Wednesday for other non-US banks, Thursday for US banks — so
    # the seller's date is their weekday within the cycle's week.
    def payout_date_for_cycle(cycle_date)
      cycle_date - days_before_cycle_date
    end

    # Inverse of payout_date_for_cycle: the Friday cycle a seller-facing payout date belongs
    # to. Used so the cycle math (which balances are included, how the period advances) keeps
    # running on Fridays even when the dates we hand out are not Fridays.
    def payout_cycle_for_payout_date(payout_date)
      payout_date + days_before_cycle_date
    end

    # How many days before the cycle's Friday the seller's rail runs. Every payout run fires
    # between Sunday and Friday of the payout week, so this is the plain distance back from
    # Friday; a rail with no weekday of its own falls back to Friday itself (zero days).
    def days_before_cycle_date
      friday_index = PayoutRailSchedule::WEEKDAYS.index(:friday)
      rail_index = PayoutRailSchedule::WEEKDAYS.index(payout_weekday) || friday_index
      (friday_index - rail_index) % PayoutRailSchedule::WEEKDAYS.size
    end

    def payout_amount_for_cycle(cycle_date)
      payout_amount_for_payout_date(payout_date_for_cycle(cycle_date))
    end

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
