# frozen_string_literal: true

require "spec_helper"

describe User::PayoutSchedule do
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
