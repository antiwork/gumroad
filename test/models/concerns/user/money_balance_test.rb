require "test_helper"

class User::MoneyBalanceTest < ActiveSupport::TestCase
  test "balance_formatted returns the user's balance" do
    user = users(:money_balance_user)
    assert_equal 100, user.unpaid_balance_cents
    assert_equal "$1", user.balance_formatted
  end

  test "#instantly_payable_unpaid_balances returns maximum unpaid balances whose sum is less than instantly payable amount available on Stripe" do
    travel_to Time.utc(2024, 6, 15, 12, 0, 0) do
      user = users(:money_balance_stripe_user)
      stripe_ma = merchant_accounts(:money_balance_stripe_account)
      gumroad_ma = merchant_accounts(:forfeit_gumroad_stripe_account)

      today = Date.today
      bal1 = create_balance(user, stripe_ma, today - 3.days, 500_00)
      bal2 = create_balance(user, stripe_ma, today - 2.days, 400_00)
      bal3 = create_balance(user, stripe_ma, today - 1.days, 300_00)
      bal4 = create_balance(user, stripe_ma, today, 200_00)
      bal5 = create_balance(user, gumroad_ma, today - 3.days, 500_00)
      bal6 = create_balance(user, gumroad_ma, today - 2.days, 500_00)
      bal7 = create_balance(user, gumroad_ma, today - 1.days, 500_00)
      bal8 = create_balance(user, gumroad_ma, today, 500_00)

      cases = {
        1400_00 => [bal1, bal2, bal3, bal4, bal5, bal6, bal7, bal8],
        1000_00 => [bal1, bal2, bal5, bal6],
        1200_00 => [bal1, bal2, bal3, bal5, bal6, bal7],
         600_00 => [bal1, bal5],
        1500_00 => [bal1, bal2, bal3, bal4, bal5, bal6, bal7, bal8],
      }

      cases.each do |cents_available, expected|
        StripePayoutProcessor.stub(:instantly_payable_amount_cents_on_stripe, ->(_) { cents_available }) do
          assert_equal expected.map(&:id).sort,
                       user.instantly_payable_unpaid_balances.map(&:id).sort,
                       "for cents_available=#{cents_available}"
        end
      end
    end
  end

  private
    def create_balance(user, merchant_account, date, cents)
      b = Balance.new(
        user: user,
        merchant_account: merchant_account,
        date: date,
        amount_cents: cents,
        holding_amount_cents: cents,
        currency: Currency::USD,
        holding_currency: Currency::USD,
        state: "unpaid",
      )
      b.save!(validate: false)
      b
    end
end
