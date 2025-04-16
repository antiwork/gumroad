# frozen_string_literal: true

describe PerformDailyInstantPayoutsWorker do
  describe "perform" do
    let(:payout_period_end_date) { Date.yesterday }

    it "calls 'create_instant_payouts_for_balances_up_to_date' on 'Payouts' which will do all the work" do
      expect(Payouts).to receive(:create_instant_payouts_for_balances_up_to_date).with(payout_period_end_date)
      described_class.new.perform
    end
  end
end
