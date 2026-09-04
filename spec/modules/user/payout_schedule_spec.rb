# frozen_string_literal: true

require "spec_helper"

describe User::PayoutSchedule do
  def pause_for_chargeback_rate!(user)
    user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
    user.comments.create!(
      content: "Payouts automatically paused due to chargeback rate (4.0%) exceeding #{User::MAX_CHARGEBACK_RATE_ALLOWED_FOR_PAYOUTS}% volume over the last #{User::PAYOUT_CHARGEBACK_RATE_WINDOW.inspect}.",
      comment_type: Comment::COMMENT_TYPE_ON_PROBATION,
      author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:high_chargeback_rate]
    )
  end

  describe "#next_payout_date" do
    let(:user) { create(:user, payment_address: "bob1@example.com") }

    context "when payout frequency is weekly" do
      it "returns the correct next payout date" do
        travel_to(Date.new(2012, 12, 26)) do
          create(:balance, user:, amount_cents: 1_000, date: Date.new(2012, 12, 20))
          expect(user.next_payout_date).to eq nil

          balance = create(:balance, user:, amount_cents: 10_000, date: Date.new(2012, 12, 21))
          expect(user.next_payout_date).to eq Date.new(2012, 12, 28)
          balance.update_attribute(:state, "paid")

          create(:balance, user:, amount_cents: 10_000, date: Date.new(2012, 12, 22))
          expect(user.next_payout_date).to eq Date.new(2013, 1, 4)
        end

        travel_to(Date.new(2013, 1, 25)) do
          expect(user.next_payout_date).to eq Date.new(2013, 1, 25)

          create(:payment, user:)
          expect(user.next_payout_date).to eq Date.new(2013, 2, 1)
        end
      end
    end

    context "when payout frequency is monthly" do
      before { user.update!(payout_frequency: "monthly") }

      it "returns the correct next payout date" do
        travel_to(Date.new(2013, 1, 15)) do
          create(:balance, user:, amount_cents: 1_000, date: Date.new(2013, 1, 14))
          expect(user.next_payout_date).to eq nil

          balance = create(:balance, user:, amount_cents: 10_000, date: Date.new(2013, 1, 15))
          expect(user.next_payout_date).to eq Date.new(2013, 1, 25)
          balance.update_attribute(:state, "paid")

          create(:balance, user:, amount_cents: 10_000, date: Date.new(2013, 1, 19))
          expect(user.next_payout_date).to eq Date.new(2013, 2, 22)
        end

        travel_to(Date.new(2013, 2, 22)) do
          expect(user.next_payout_date).to eq Date.new(2013, 2, 22)

          create(:payment, user:)
          expect(user.next_payout_date).to eq Date.new(2013, 3, 29)
        end
      end
    end

    context "when payout frequency is quarterly" do
      before { user.update!(payout_frequency: "quarterly") }

      it "returns the correct next payout date" do
        travel_to(Date.new(2013, 3, 15)) do
          create(:balance, user:, amount_cents: 1_000, date: Date.new(2013, 3, 14))
          expect(user.next_payout_date).to eq nil

          balance = create(:balance, user:, amount_cents: 10_000, date: Date.new(2013, 3, 15))
          expect(user.next_payout_date).to eq Date.new(2013, 3, 29)
          balance.update_attribute(:state, "paid")

          create(:balance, user:, amount_cents: 10_000, date: Date.new(2013, 3, 23))
          expect(user.next_payout_date).to eq Date.new(2013, 6, 28)
        end

        travel_to(Date.new(2013, 6, 28)) do
          expect(user.next_payout_date).to eq Date.new(2013, 6, 28)

          create(:payment, user:)
          expect(user.next_payout_date).to eq Date.new(2013, 9, 27)
        end
      end
    end

    context "when payout frequency is daily" do
      before { user.update!(payout_frequency: User::PayoutSchedule::DAILY) }

      it "returns tomorrow when the seller is eligible for an instant payout" do
        travel_to(Date.new(2025, 9, 22)) do
          create(:balance, user:, amount_cents: 10_000, date: Date.new(2025, 9, 18))
          allow(Payouts).to receive(:is_user_payable).and_call_original
          allow(Payouts).to receive(:is_user_payable)
            .with(user, Date.current, payout_type: Payouts::PAYOUT_TYPE_INSTANT).and_return(true)

          expect(user.next_payout_date).to eq Date.new(2025, 9, 23)
          # Asking twice must give the same answer: the eligibility check is remembered for the
          # day, and a memo that never returns its remembered value would fall back to the
          # weekly cycle instead.
          expect(user.next_payout_date).to eq Date.new(2025, 9, 23)
          expect(Payouts).to have_received(:is_user_payable)
            .with(user, Date.current, payout_type: Payouts::PAYOUT_TYPE_INSTANT).once
        end
      end

      it "falls back to the weekly cycle when the seller is not eligible for an instant payout" do
        travel_to(Date.new(2025, 9, 22)) do
          create(:balance, user:, amount_cents: 10_000, date: Date.new(2025, 9, 18))
          allow(Payouts).to receive(:is_user_payable).and_call_original
          allow(Payouts).to receive(:is_user_payable)
            .with(user, anything, payout_type: Payouts::PAYOUT_TYPE_INSTANT).and_return(false)

          expect(user.next_payout_date).to eq Date.new(2025, 9, 26)
        end
      end

      it "falls back to the scheduled reserve payout when daily instant payouts are held" do
        travel_to(Date.new(2025, 9, 22)) do
          daily_seller = create(:user_with_compliance_info, payment_address: "daily@example.com", payout_frequency: User::PayoutSchedule::DAILY)
          daily_seller.update!(user_risk_state: "compliant")
          merchant_account = create(:merchant_account, user: daily_seller)
          4.times do |i|
            create(:balance, user: daily_seller, merchant_account:, amount_cents: 100_00, date: Date.new(2025, 9, 18) + i)
          end
          pause_for_chargeback_rate!(daily_seller)

          expect(Payouts.is_user_payable(daily_seller, Date.current, payout_type: Payouts::PAYOUT_TYPE_INSTANT)).to eq(false)
          expect(daily_seller.next_payout_date).to eq Date.new(2025, 9, 26)
          payout_period_end_date = daily_seller.payout_period_end_date_for_payout_date(daily_seller.next_payout_date)
          expect(Payouts.is_user_payable(daily_seller, payout_period_end_date)).to eq(true)
        end
      end
    end
  end

  describe "#upcoming_payouts" do
    let(:user) { create(:user, payment_address: "bob1@example.com") }

    around do |example|
      travel_to(Date.new(2025, 9, 22)) do
        example.run
      end
    end

    context "when payout frequency is weekly" do
      it "returns nothing if the user has no unpaid balance" do
        expect(user.upcoming_payouts).to eq([])
      end

      it "returns the correct upcoming payouts" do
        balance_1 = create(:balance, user:, amount_cents: 1_000, date: Date.new(2025, 9, 17))
        balance_2 = create(:balance, user:, amount_cents: 10_000, date: Date.new(2025, 9, 18))
        expect(user.upcoming_payouts.size).to eq 1
        expect(user.upcoming_payouts[0].created_at).to eq(Date.new(2025, 9, 26))
        expect(user.upcoming_payouts[0].amount_cents).to eq 11_000
        expect(user.upcoming_payouts[0].balances).to match_array [balance_1, balance_2]

        balance_3 = create(:balance, user:, amount_cents: 10_000, date: Date.new(2025, 9, 22))
        expect(user.upcoming_payouts.size).to eq 2
        expect(user.upcoming_payouts[0].created_at).to eq(Date.new(2025, 9, 26))
        expect(user.upcoming_payouts[0].amount_cents).to eq 11_000
        expect(user.upcoming_payouts[0].balances).to match_array [balance_1, balance_2]
        expect(user.upcoming_payouts[1].created_at).to eq(Date.new(2025, 10, 3))
        expect(user.upcoming_payouts[1].amount_cents).to eq 10_000
        expect(user.upcoming_payouts[1].balances).to match_array [balance_3]
      end
    end
  end

  describe "#payout_amount_for_payout_date" do
    let(:user) { create(:user, payment_address: "bob1@example.com") }

    context "when payout frequency is weekly" do
      it "calculates the correct payout amount" do
        travel_to(Date.new(2013, 1, 25)) do
          create(:balance, user:, amount_cents: 1_000, date: Date.new(2012, 12, 20))
          create(:balance, user:, amount_cents: 10_000, date: Date.new(2012, 12, 21))
          create(:payment, user:)

          expect(user.payout_amount_for_payout_date(user.next_payout_date)).to eq 11_000

          create(:balance, user:, amount_cents: 10_000, date: Date.new(2013, 2, 1))
          expect(user.payout_amount_for_payout_date(user.next_payout_date)).to eq 11_000
        end
      end
    end
  end

  describe ".next_scheduled_payout_date" do
    # These use a local-time midday so the frozen clock lands on the intended calendar
    # day regardless of the machine's timezone — the method reads Date.today, which is
    # the system date rather than the Rails-zone date.
    it "returns today when today is already a Friday" do
      travel_to(Time.local(2026, 7, 24, 12)) do
        expect(described_class.next_scheduled_payout_date).to eq Date.new(2026, 7, 24)
      end
    end

    it "returns the coming Friday on every other day of the week" do
      {
        Time.local(2026, 7, 25, 12) => Date.new(2026, 7, 31), # Saturday
        Time.local(2026, 7, 26, 12) => Date.new(2026, 7, 31), # Sunday
        Time.local(2026, 7, 27, 12) => Date.new(2026, 7, 31), # Monday
        Time.local(2026, 7, 28, 12) => Date.new(2026, 7, 31), # Tuesday
        Time.local(2026, 7, 29, 12) => Date.new(2026, 7, 31), # Wednesday
        Time.local(2026, 7, 30, 12) => Date.new(2026, 7, 31), # Thursday
      }.each do |today, expected_payout_date|
        travel_to(today) do
          expect(described_class.next_scheduled_payout_date).to eq expected_payout_date
        end
      end
    end

    it "crosses month and year boundaries" do
      travel_to(Time.local(2026, 12, 31, 12)) do # Thursday
        expect(described_class.next_scheduled_payout_date).to eq Date.new(2027, 1, 1)
      end
    end

    # This method describes the platform-wide payout run (the Friday cron), not any
    # individual seller's schedule. A seller on a monthly or quarterly frequency is paid
    # on their own date, which comes from the per-seller #next_payout_date below. Nothing
    # shown to a seller should be derived from this method — see the spec that follows.
    it "describes the platform-wide Friday run, not an individual seller's payout date" do
      travel_to(Time.local(2026, 7, 22, 12)) do # Wednesday
        monthly_seller = create(:user, payment_address: "monthly@example.com")
        monthly_seller.update!(payout_frequency: User::PayoutSchedule::MONTHLY)
        create(:balance, user: monthly_seller, amount_cents: 10_000, date: Date.new(2026, 7, 1))

        expect(described_class.next_scheduled_payout_date).to eq Date.new(2026, 7, 24)
        expect(monthly_seller.next_payout_date).to eq Date.new(2026, 7, 31)
      end
    end
  end

  describe "seller-facing payout dates respect the seller's own frequency" do
    # Guards the accuracy concern raised on the change that made
    # .next_scheduled_payout_date compute from the current week: everything a seller
    # sees (Payouts page, settings, emails, admin "next payout date") reads
    # #next_payout_date, which branches on the seller's payout_frequency.
    it "returns a different date per frequency for the same balance and clock" do
      travel_to(Time.local(2026, 7, 22, 12)) do # Wednesday
        balances_for = lambda do |frequency, email|
          create(:user, payment_address: email).tap do |seller|
            seller.update!(payout_frequency: frequency)
            create(:balance, user: seller, amount_cents: 10_000, date: Date.new(2026, 7, 1))
          end
        end

        weekly_seller = balances_for.call(User::PayoutSchedule::WEEKLY, "weekly@example.com")
        monthly_seller = balances_for.call(User::PayoutSchedule::MONTHLY, "monthly@example.com")
        quarterly_seller = balances_for.call(User::PayoutSchedule::QUARTERLY, "quarterly@example.com")

        expect(weekly_seller.next_payout_date).to eq Date.new(2026, 7, 24)
        expect(monthly_seller.next_payout_date).to eq Date.new(2026, 7, 31)
        expect(quarterly_seller.next_payout_date).to eq Date.new(2026, 9, 25)
      end
    end
  end

  describe "#payout_weekday" do
    it "is the weekday of the run that pays the seller's bank account type" do
      cross_border_seller = create(:philippines_bank_account).user
      non_us_seller = create(:uk_bank_account).user
      us_seller = create(:ach_account).user
      paypal_seller = create(:user, payment_address: "paypal@example.com")

      expect(cross_border_seller.payout_weekday).to eq :tuesday
      expect(non_us_seller.payout_weekday).to eq :wednesday
      expect(us_seller.payout_weekday).to eq :thursday
      expect(paypal_seller.payout_weekday).to eq :friday
    end

    it "does not look up which processor pays a seller who has no bank account" do
      # The PayPal and Stripe Connect runs share a weekday, so the answer is the same either
      # way — and finding out which of the two applies is expensive, because it reads
      # paypal_payout_email, which calls PayPal's API for a seller who connected a PayPal
      # account rather than giving us an email address. next_payout_date runs for every seller
      # the weekly payout batch considers, so that call must not happen here.
      seller = create(:user)

      expect(seller).not_to receive(:current_payout_processor)
      expect(seller.payout_weekday).to eq :friday
    end
  end

  describe "#next_payout_date on a non-Friday payout rail" do
    # The bug this covers: the projected date was always the platform's Friday cycle date, so a
    # seller whose rail runs on Tuesday was told a day they could never be paid on, wrote in on
    # that day asking where the money was, and support repeated the wrong date back to them.
    it "lands on the seller's own rail weekday, not the platform Friday" do
      travel_to(Time.local(2026, 7, 22, 12)) do # Wednesday
        seller_for = lambda do |factory|
          create(factory).user.tap do |seller|
            create(:balance, user: seller, amount_cents: 10_000, date: Date.new(2026, 7, 10))
          end
        end

        cross_border_seller = seller_for.call(:philippines_bank_account)
        non_us_seller = seller_for.call(:uk_bank_account)
        us_seller = seller_for.call(:ach_account)
        paypal_seller = create(:user, payment_address: "paypal@example.com")
        create(:balance, user: paypal_seller, amount_cents: 10_000, date: Date.new(2026, 7, 10))

        expect(cross_border_seller.next_payout_date).to eq Date.new(2026, 7, 28) # next Tuesday
        expect(non_us_seller.next_payout_date).to eq Date.new(2026, 7, 22)       # today, a Wednesday
        expect(us_seller.next_payout_date).to eq Date.new(2026, 7, 23)           # Thursday
        expect(paypal_seller.next_payout_date).to eq Date.new(2026, 7, 24)       # Friday
      end
    end

    it "does not project a date that has already passed this week" do
      # Wednesday: the Tuesday run for this cycle has already fired, so the seller's next date
      # is next week's Tuesday rather than yesterday.
      travel_to(Time.local(2026, 7, 22, 12)) do # Wednesday
        seller = create(:philippines_bank_account).user
        create(:balance, user: seller, amount_cents: 10_000, date: Date.new(2026, 7, 10))

        expect(seller.next_payout_date).to eq Date.new(2026, 7, 28)
      end
    end

    it "returns today when today is the seller's payout day" do
      travel_to(Time.local(2026, 7, 28, 12)) do # Tuesday
        seller = create(:philippines_bank_account).user
        create(:balance, user: seller, amount_cents: 10_000, date: Date.new(2026, 7, 10))

        expect(seller.next_payout_date).to eq Date.new(2026, 7, 28)
      end
    end

    it "covers the same balance period the payout job will actually pay on that day" do
      # The payout jobs all pay balances up to User::PayoutSchedule.next_scheduled_payout_end_date,
      # whichever weekday they fire on, so the period a seller's projected payout covers must
      # match what the job computes on the seller's own payout day. Getting this wrong would show
      # the seller the right day with the wrong amount.
      {
        philippines_bank_account: Date.new(2026, 7, 28), # Tuesday run
        uk_bank_account: Date.new(2026, 7, 29),          # Wednesday run
        ach_account: Date.new(2026, 7, 30),              # Thursday run
      }.each do |bank_account_factory, payout_day|
        seller = create(bank_account_factory).user
        create(:balance, user: seller, amount_cents: 10_000, date: Date.new(2026, 7, 10))

        travel_to(payout_day.in_time_zone.change(hour: 12)) do
          expect(seller.next_payout_date).to eq payout_day
          expect(seller.payout_period_end_date_for_payout_date(payout_day))
            .to eq User::PayoutSchedule.next_scheduled_payout_end_date
        end
      end
    end

    it "advances to the next cycle when the seller was already paid today" do
      travel_to(Time.local(2026, 7, 28, 12)) do # Tuesday
        seller = create(:philippines_bank_account).user
        create(:balance, user: seller, amount_cents: 10_000, date: Date.new(2026, 7, 10))
        create(:payment, user: seller)

        expect(seller.next_payout_date).to eq Date.new(2026, 8, 4) # the following Tuesday
      end
    end

    it "keeps monthly and quarterly frequencies on their own cycle while moving the weekday" do
      travel_to(Time.local(2026, 7, 22, 12)) do # Wednesday
        monthly_seller = create(:philippines_bank_account).user
        monthly_seller.update!(payout_frequency: User::PayoutSchedule::MONTHLY)
        create(:balance, user: monthly_seller, amount_cents: 10_000, date: Date.new(2026, 7, 1))

        # Last Friday of July is the 31st, so the Tuesday of that payout week is the 28th.
        expect(monthly_seller.next_payout_date).to eq Date.new(2026, 7, 28)
      end
    end
  end

  describe "#upcoming_payouts on a non-Friday payout rail" do
    it "spaces the projected payouts a week apart on the seller's weekday" do
      travel_to(Time.local(2025, 9, 22, 12)) do # Monday
        seller = create(:philippines_bank_account).user
        create(:balance, user: seller, amount_cents: 11_000, date: Date.new(2025, 9, 18))
        create(:balance, user: seller, amount_cents: 10_000, date: Date.new(2025, 9, 22))

        upcoming = seller.upcoming_payouts
        expect(upcoming.size).to eq 2
        expect(upcoming[0].created_at).to eq Date.new(2025, 9, 23) # Tuesday
        expect(upcoming[0].amount_cents).to eq 11_000
        expect(upcoming[1].created_at).to eq Date.new(2025, 9, 30) # the next Tuesday
        expect(upcoming[1].amount_cents).to eq 10_000
      end
    end
  end

  describe ".manual_payout_end_date" do
    it "returns the date upto which creators are expected to have been automatically paid out till now" do
      today = Date.today
      last_weeks_friday = today.beginning_of_week - 3
      (today.beginning_of_week..today.end_of_week).each do |date|
        travel_to(date) do
          if Date.today.wday == 1
            expect(described_class.manual_payout_end_date).to eq last_weeks_friday - 7
          else
            expect(described_class.manual_payout_end_date).to eq last_weeks_friday
          end
        end
      end
    end
  end
end
