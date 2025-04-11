# frozen_string_literal: true

require "spec_helper"

describe User::MoneyBalance, :vcr do
  describe "balance_formatted" do
    before do
      @user = create(:user, unpaid_balance_cents: 1_00)
    end

    it "returns the user's balance" do
      expect(@user.unpaid_balance_cents).to eq 100
      expect(@user.balance_formatted).to eq "$1"
    end
  end

  describe "#instantly_payable_unpaid_balances" do
    it "returns maximum unpaid balances whose sum is less than instantly payable amount available on Stripe" do
      user = create(:user)
      merchant_account = create(:merchant_account_stripe, user:)

      bal1 = create(:balance, user:, merchant_account:, date: Date.current - 3.days, amount_cents: 500_00, holding_amount_cents: 500_00)
      bal2 = create(:balance, user:, merchant_account:, date: Date.current - 2.days, amount_cents: 400_00, holding_amount_cents: 400_00)
      bal3 = create(:balance, user:, merchant_account:, date: Date.current - 1.days, amount_cents: 300_00, holding_amount_cents: 300_00)
      bal4 = create(:balance, user:, merchant_account:, date: Date.current, amount_cents: 200_00, holding_amount_cents: 200_00)
      bal5 = create(:balance, user:, date: Date.current - 3.days, amount_cents: 500_00, holding_amount_cents: 500_00)
      bal6 = create(:balance, user:, date: Date.current - 2.days, amount_cents: 500_00, holding_amount_cents: 500_00)
      bal7 = create(:balance, user:, date: Date.current - 1.days, amount_cents: 500_00, holding_amount_cents: 500_00)
      bal8 = create(:balance, user:, date: Date.current, amount_cents: 500_00, holding_amount_cents: 500_00)

      allow(StripePayoutProcessor).to receive(:instantly_payable_amount_cents_on_stripe).with(user).and_return(1400_00)
      expect(user.instantly_payable_unpaid_balances).to match_array([bal1, bal2, bal3, bal4, bal5, bal6, bal7, bal8])

      allow(StripePayoutProcessor).to receive(:instantly_payable_amount_cents_on_stripe).with(user).and_return(1000_00)
      expect(user.instantly_payable_unpaid_balances).to match_array([bal1, bal2, bal5, bal6])

      allow(StripePayoutProcessor).to receive(:instantly_payable_amount_cents_on_stripe).with(user).and_return(1200_00)
      expect(user.instantly_payable_unpaid_balances).to match_array([bal1, bal2, bal3, bal5,  bal6, bal7])

      allow(StripePayoutProcessor).to receive(:instantly_payable_amount_cents_on_stripe).with(user).and_return(600_00)
      expect(user.instantly_payable_unpaid_balances).to match_array([bal1, bal5])

      allow(StripePayoutProcessor).to receive(:instantly_payable_amount_cents_on_stripe).with(user).and_return(1500_00)
      expect(user.instantly_payable_unpaid_balances).to match_array([bal1, bal2, bal3, bal4, bal5, bal6, bal7, bal8])
    end
  end
end
