# frozen_string_literal: true

require "test_helper"

class PaypalBalanceCheckServiceTest < ActiveSupport::TestCase
  setup do
    @seller = users(:paypal_seller)
    # Isolate to the paypal_seller's balances/payments — the global fixture
    # set contains other paypal payments + unpaid balances (e.g. PayoutEstimates
    # fixtures, failure_reason_payment) that would otherwise leak into the
    # service's aggregate queries and inflate payout_amount_cents.
    Balance.where.not(user_id: @seller.id).delete_all
    Payment.where.not(user_id: @seller.id).delete_all
  end

  # Helper to stub PaypalPayoutProcessor responses for a block.
  def with_paypal(current_balance_cents:, topup_in_transit_dollars: 0)
    PaypalPayoutProcessor.stub(:current_paypal_balance_cents, current_balance_cents) do
      PaypalPayoutProcessor.stub(:topup_amount_in_transit, topup_in_transit_dollars) do
        yield
      end
    end
  end

  test "#topup_needed? returns false when balance is sufficient for payouts" do
    Balance.delete_all
    with_paypal(current_balance_cents: 100_000_00) do
      service = PaypalBalanceCheckService.new
      assert_equal false, service.topup_needed?
    end
  end

  test "#topup_needed? returns true when balance is insufficient for payouts" do
    payments(:paypal_payment_recent) # ensure loaded
    balances(:paypal_seller_unpaid_balance)
    with_paypal(current_balance_cents: 50_000_00) do
      service = PaypalBalanceCheckService.new
      assert_equal true, service.topup_needed?
    end
  end

  test "#topup_needed? returns false when balance is low but topup is in transit" do
    payments(:paypal_payment_recent)
    balances(:paypal_seller_unpaid_balance)
    with_paypal(current_balance_cents: 50_000_00, topup_in_transit_dollars: 200_000) do
      service = PaypalBalanceCheckService.new
      assert_equal false, service.topup_needed?
    end
  end

  test "#payout_amount_cents returns the total amount needed for upcoming PayPal payouts" do
    payments(:paypal_payment_recent)
    bal = balances(:paypal_seller_unpaid_balance)
    bal.update_columns(amount_cents: 15_000_000, holding_amount_cents: 15_000_000)
    with_paypal(current_balance_cents: 100_000_00) do
      service = PaypalBalanceCheckService.new
      assert_equal 150_000_00, service.payout_amount_cents
    end
  end

  test "#payout_amount_cents returns 0 when there are no PayPal payments" do
    Payment.where(processor: "paypal").update_all(processor: "STRIPE")
    balances(:paypal_seller_unpaid_balance)
    with_paypal(current_balance_cents: 100_000_00) do
      service = PaypalBalanceCheckService.new
      assert_equal 0, service.payout_amount_cents
    end
  end

  test "#payout_amount_cents does not include the balance when payment is older than 1 month" do
    Payment.where(processor: "paypal").update_all(created_at: 2.months.ago)
    balances(:paypal_seller_unpaid_balance)
    with_paypal(current_balance_cents: 100_000_00) do
      service = PaypalBalanceCheckService.new
      assert_equal 0, service.payout_amount_cents
    end
  end

  test "#current_balance_cents returns the current PayPal balance" do
    with_paypal(current_balance_cents: 75_000_00) do
      service = PaypalBalanceCheckService.new
      assert_equal 75_000_00, service.current_balance_cents
    end
  end

  test "#topup_in_transit_cents returns the topup amount in transit in cents" do
    with_paypal(current_balance_cents: 100_000_00, topup_in_transit_dollars: 100_000) do
      service = PaypalBalanceCheckService.new
      assert_equal 100_000_00, service.topup_in_transit_cents
    end
  end

  test "#topup_amount_cents returns the amount needed to top up" do
    payments(:paypal_payment_recent)
    bal = balances(:paypal_seller_unpaid_balance)
    bal.update_columns(amount_cents: 20_000_000, holding_amount_cents: 20_000_000)
    with_paypal(current_balance_cents: 50_000_00, topup_in_transit_dollars: 50_000) do
      service = PaypalBalanceCheckService.new
      assert_equal 100_000_00, service.topup_amount_cents
    end
  end
end
