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

    # Without a bank account the seller is paid either through PayPal or through their own
    # connected Stripe account. Both of those runs are scheduled on the same weekday, so
    # normally we can answer without working out which of the two applies — and that matters,
    # because deciding is expensive: current_payout_processor reads paypal_payout_email, which
    # calls PayPal's API for a seller who connected a PayPal account instead of giving us an
    # email address. next_payout_date is called for every seller the weekly payout batch
    # considers, so an API call per seller there is not affordable.
    paypal_weekday = PayoutRailSchedule.paypal_weekday
    stripe_connect_weekday = PayoutRailSchedule.stripe_connect_weekday
    return paypal_weekday if paypal_weekday == stripe_connect_weekday

    current_payout_processor == PayoutProcessorType::PAYPAL ? paypal_weekday : stripe_connect_weekday
  end

  # The payout CYCLE the seller's next payout belongs to: the Friday of the platform's payout
  # week that decides which balances the payout covers. This is the seller's payout schedule
  # as it has always been computed, and anything comparing a payout BATCH to a seller must use
  # it rather than #next_payout_date. The batch is scheduled by the cycle, while the seller's
  # own payout day sits earlier in the same week (see #payout_weekday) — comparing against
  # that day would make a batch running later in the week, such as a retried dead job, look
  # like it belonged to the following week and skip every seller in it.
  #
  # For a seller on daily payouts the value is tomorrow rather than a Friday: their payout is
  # not part of the weekly cycle at all.
  def next_payout_cycle_date
    return nil if unpaid_balance_cents < minimum_payout_amount_cents

    return Date.current + 1 if instant_daily_payout?

    payout_cycle_date = get_initial_payout_date(Date.today)

    payout_cycle_date = advance_payout_date(payout_cycle_date) until payout_cycle_date >= Date.today

    if payout_amount_for_cycle(payout_cycle_date) < minimum_payout_amount_cents
      payout_cycle_date = advance_payout_date(payout_cycle_date)
    end

    # Already paid within this cycle today: the cycle is spent, so the seller's next payout
    # belongs to the following one. Without this the payout batch would consider them again
    # on the same day.
    if payout_cycle_date == Date.today && payments.where("date(created_at) = ?", Date.today).first.present?
      payout_cycle_date = advance_payout_date(payout_cycle_date)
    end

    payout_cycle_date
  end

  def next_payout_date
    payout_cycle_date = next_payout_cycle_date
    return nil if payout_cycle_date.nil?

    # A daily seller's date is already the date they are paid, not a cycle to convert.
    return payout_cycle_date if instant_daily_payout?

    # The cycle stays anchored on the platform's Friday-to-Friday week (that is what decides
    # which balances are included); the day the seller is actually paid is their rail's weekday
    # inside that cycle.
    upcoming_payout_date = payout_date_for_cycle(payout_cycle_date)

    # Their rail may already have run earlier this week — the cycle is still this week's, but
    # the day they would have been paid on has passed, so the next one they can be paid on is
    # in the following cycle. Same when they have already been paid today.
    already_paid_today = upcoming_payout_date == Date.today && payments.where("date(created_at) = ?", Date.today).first.present?
    if upcoming_payout_date < Date.today || already_paid_today
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
    return [] if upcoming_payout_date.nil?

    # Track the Friday cycle alongside the seller-facing date: the cycle is what advances a week
    # (or a month, or a quarter) at a time, and the seller's date is that cycle converted to their
    # rail's weekday. A daily seller's first date is tomorrow rather than a cycle date at all, so
    # for them start from the cycle their fallback weekly payout would use.
    payout_cycle_date = if instant_daily_payout?
      get_initial_payout_date(upcoming_payout_date)
    else
      payout_cycle_for_payout_date(upcoming_payout_date)
    end
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

      payout_cycle_date = advance_payout_date(payout_cycle_date)
      upcoming_payout_date = payout_date_for_cycle(payout_cycle_date)
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
    # Whether the seller's next payout is a daily instant payout, which sits outside the
    # weekly cycle entirely (it pays yesterday's instantly-payable balance, tomorrow).
    # Answering it runs the full eligibility check, so the answer is remembered per day —
    # #next_payout_date and #next_payout_cycle_date both ask, and the batch gate asks for
    # every seller it considers.
    def instant_daily_payout?
      return false unless payout_frequency == DAILY

      today = Date.current
      return @instant_daily_payout unless @instant_daily_payout_on == today

      @instant_daily_payout_on = today
      @instant_daily_payout = Payouts.is_user_payable(self, today, payout_type: Payouts::PAYOUT_TYPE_INSTANT)
    end

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
    #
    # Memoized for the life of the object: the conversion happens inside loops (the cycle
    # search in #next_payout_date, the projection in #upcoming_payouts) and resolving the rail
    # reads the seller's bank account, so recomputing it per iteration means a query per
    # iteration for no benefit — a seller's rail cannot change mid-request.
    def days_before_cycle_date
      return @days_before_cycle_date if defined?(@days_before_cycle_date)

      friday_index = PayoutRailSchedule::WEEKDAYS.index(:friday)
      rail_index = PayoutRailSchedule::WEEKDAYS.index(payout_weekday) || friday_index
      @days_before_cycle_date = (friday_index - rail_index) % PayoutRailSchedule::WEEKDAYS.size
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
