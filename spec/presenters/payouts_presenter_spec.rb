# frozen_string_literal: true

describe PayoutsPresenter do
  include PayoutsHelper
  include CurrencyHelper

  describe "#next_payout_period_data" do
    it "returns not_payable status when user balance is below minimum" do
      user = create(:user, user_risk_state: "compliant")
      instance = described_class.new(seller: user)

      expect(instance.next_payout_period_data).to include(
        status: "not_payable",
        is_user_payable: false,
        has_stripe_connect: false
      )
    end

    it "returns has_stripe_connect set to false if the user is not stripe connect" do
      user = create(:user, user_risk_state: "compliant")
      instance = described_class.new(seller: user)

      expect(instance.next_payout_period_data).to include(has_stripe_connect: false)
    end

    it "returns has_stripe_connect set to true if the user is stripe connect" do
      user = create(:user, user_risk_state: "compliant")
      MerchantAccount.create!(
        user: user,
        charge_processor_id: StripeChargeProcessor.charge_processor_id,
        charge_processor_merchant_id: "acct_test123",
        charge_processor_verified_at: Time.current,
        charge_processor_alive_at: Time.current,
        json_data: { meta: { stripe_connect: "true" } }
      )
      instance = described_class.new(seller: user)

      expect(instance.next_payout_period_data).to include(has_stripe_connect: true)
    end
  end

  describe "#processing_payout_periods_data" do
    it "returns empty array when no processing payouts exist" do
      user = create(:user, user_risk_state: "compliant")
      instance = described_class.new(seller: user)

      expect(instance.processing_payout_periods_data).to eq([])
    end

    it "adds has_stripe_connect to each processing payout period" do
      user = create(:user, user_risk_state: "compliant")
      MerchantAccount.create!(
        user: user,
        charge_processor_id: StripeChargeProcessor.charge_processor_id,
        charge_processor_merchant_id: "acct_test123",
        charge_processor_verified_at: Time.current,
        charge_processor_alive_at: Time.current,
        json_data: { meta: { stripe_connect: "true" } }
      )
      instance = described_class.new(seller: user)

      instance.processing_payout_periods_data.each do |period|
        expect(period).to include(has_stripe_connect: true)
      end
    end
  end

  describe "#instant_payout_data" do
    it "returns nil when instant payouts are not supported" do
      user = create(:user, user_risk_state: "compliant")
      instance = described_class.new(seller: user)

      expect(instance.instant_payout_data).to be_nil
    end

    it "returns instant payout details when supported" do
      user = create(:user, user_risk_state: "compliant")
      instance = described_class.new(seller: user)

      allow(user).to receive(:instant_payouts_supported?).and_return(true)
      allow(user).to receive(:instantly_payable_unpaid_balance_cents).and_return(1000)
      allow(user).to receive(:instantly_payable_unpaid_balances).and_return([])
      allow(user).to receive_message_chain(:active_bank_account, :bank_account_type).and_return("checking")
      allow(user).to receive_message_chain(:active_bank_account, :bank_name).and_return("Test Bank")
      allow(user).to receive_message_chain(:active_bank_account, :routing_number).and_return("123456789")
      allow(user).to receive_message_chain(:active_bank_account, :account_number_visual).and_return("****1234")

      expect(instance.instant_payout_data).to eq(
        {
          payable_amount_cents: 1000,
          payable_balances: [],
          bank_account_type: "checking",
          bank_name: "Test Bank",
          routing_number: "123456789",
          account_number: "****1234"
        }
      )
    end
  end

  describe "#past_payout_period_data" do
    it "returns empty array when no past payouts exist" do
      user = create(:user, user_risk_state: "compliant")
      instance = described_class.new(seller: user)

      expect(instance.past_payout_period_data).to eq([])
    end

    it "transforms past payouts using payout_period_data helper" do
      user = create(:user, user_risk_state: "compliant")
      create(:payment_completed, user: user)
      instance = described_class.new(seller: user)

      result = instance.past_payout_period_data
      expect(result.length).to eq(1)
      expect(result.first).to include(:payout_displayed_amount)
    end
  end

  describe "#pagination_data" do
    it "returns pagination props" do
      user = create(:user, user_risk_state: "compliant")
      create_list(:payment_completed, 5, user: user)
      instance = described_class.new(seller: user)

      result = instance.pagination_data
      expect(result).to include(:pages)
    end
  end
end
