# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"

describe Admin::PaydaysController do
  it_behaves_like "inherits from Admin::BaseController"

  let(:next_scheduled_payout_end_date) { User::PayoutSchedule.next_scheduled_payout_end_date }

  before do
    user = create(:admin_user)
    sign_in(user)
  end

  describe "POST 'pay_user'" do
    before do
      @user = create(:singaporean_user_with_compliance_info, user_risk_state: "compliant", payment_address: "bob@example.com")
      create(:balance, user: @user, amount_cents: 1000, date: next_scheduled_payout_end_date - 3)
      create(:balance, user: @user, amount_cents: 500, date: next_scheduled_payout_end_date)
      create(:balance, user: @user, amount_cents: 2000, date: next_scheduled_payout_end_date + 1)
    end

    it "pays the seller for balances up to and including the date passed in params" do
      WebMock.stub_request(:post, PAYPAL_ENDPOINT).to_return(body: "CORRELATIONID=c51c5e0cecbce&ACK=Success")

      post :pay_user, params: { id: @user.id, payday: { payout_processor: PayoutProcessorType::PAYPAL, payout_period_end_date: next_scheduled_payout_end_date } }

      expect(response).to be_redirect
      expect(flash[:notice]).to eq("Payment was sent.")
      last_payment = Payment.last
      expect(last_payment.user_id).to eq(@user.id)
      expect(last_payment.amount_cents).to eq(1470)
      expect(last_payment.state).to eq("processing")
      expect(@user.unpaid_balance_cents).to eq(2000)
    end

    it "does not pay the user if there are pending payments" do
      create(:payment, user: @user)

      post :pay_user, params: { id: @user.id, payday: { payout_processor: PayoutProcessorType::PAYPAL, payout_period_end_date: next_scheduled_payout_end_date } }

      expect(response).to be_redirect
      expect(flash[:notice]).to eq("Payment was not sent.")
      expect(@user.payments.count).to eq(1)
    end

    it "attempts to pay the user via Stripe if the `payout_processor` is 'STRIPE'" do
      expect(Payouts).to receive(:create_payments_for_balances_up_to_date_for_users).with(next_scheduled_payout_end_date,
                                                                                          PayoutProcessorType::STRIPE, [@user], from_admin: true
                                                                                          ).and_return([Payment.last])

      post :pay_user, params: { id: @user.id, payday: { payout_processor: PayoutProcessorType::STRIPE, payout_period_end_date: next_scheduled_payout_end_date } }

      expect(response).to be_redirect
      expect(flash[:notice]).to eq("Payment was not sent.")
    end
  end
end
