# frozen_string_literal: true

require "test_helper"

class UserPayoutScheduleTest < ActiveSupport::TestCase
  self.described_class = User::PayoutSchedule



  context_ User::PayoutSchedule do
  context_ "#next_payout_date" do
      let(:user) { create(:user, payment_address: "bob1@example.com") }

  context_ "when payout frequency is weekly" do
  test "returns the correct next payout date" do
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

  context_ "when payout frequency is monthly" do
        before { user.update!(payout_frequency: "monthly") }

  test "returns the correct next payout date" do
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

  context_ "when payout frequency is quarterly" do
        before { user.update!(payout_frequency: "quarterly") }

  test "returns the correct next payout date" do
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

  context_ "#upcoming_payouts" do
      let(:user) { create(:user, payment_address: "bob1@example.com") }

      around do |example|
        travel_to(Date.new(2025, 9, 22)) do
          example.run
        end
      end

  context_ "when payout frequency is weekly" do
  test "returns nothing if the user has no unpaid balance" do
          expect(user.upcoming_payouts).to eq([])
        end

  test "returns the correct upcoming payouts" do
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

  context_ "#payout_amount_for_payout_date" do
      let(:user) { create(:user, payment_address: "bob1@example.com") }

  context_ "when payout frequency is weekly" do
  test "calculates the correct payout amount" do
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

  context_ ".manual_payout_end_date" do
  test "returns the date upto which creators are expected to have been automatically paid out till now" do
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
end
