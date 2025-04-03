# frozen_string_literal: true

describe PerformPayoutsUpToDelayDaysAgoWorker do
  describe "perform" do
    let(:payout_period_end_date) { User::PayoutSchedule.next_scheduled_payout_end_date }
    let(:payout_processor_type) { PayoutProcessorType::PAYPAL }

    it "calls 'create_payments_for_balances_up_to_date' on 'Payouts' which will do all the work" do
      expect(Payouts).to receive(:create_payments_for_balances_up_to_date).with(payout_period_end_date, payout_processor_type)
      described_class.new.perform(payout_processor_type)
    end
  end
end
