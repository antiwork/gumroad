# frozen_string_literal: true

describe PerformPayoutsUpToDelayDaysAgoWorker do
  describe "perform" do
    let(:payout_period_end_date) { User::PayoutSchedule.next_scheduled_payout_end_date }
    let(:payout_processor_type) { PayoutProcessorType::PAYPAL }

    it "calls 'create_payments_for_balances_up_to_date' on 'Payouts' which will do all the work" do
      expect(Payouts).to receive(:create_payments_for_balances_up_to_date).with(payout_period_end_date, payout_processor_type)
      described_class.new.perform(payout_processor_type)
    end

    context "with a single bank account type" do
      it "processes the type directly without fanning out" do
        expect(Payouts).to receive(:create_payments_for_balances_up_to_date_for_bank_account_types)
          .with(payout_period_end_date, PayoutProcessorType::STRIPE, ["AchAccount"])
        expect(described_class).not_to receive(:perform_async)

        described_class.new.perform(PayoutProcessorType::STRIPE, ["AchAccount"])
      end
    end

    context "with multiple bank account types" do
      it "fans out to one isolated job per bank account type and does not process inline" do
        expect(Payouts).not_to receive(:create_payments_for_balances_up_to_date_for_bank_account_types)
        expect(described_class).to receive(:perform_async).with(PayoutProcessorType::STRIPE, ["AchAccount"])
        expect(described_class).to receive(:perform_async).with(PayoutProcessorType::STRIPE, ["CardBankAccount"])

        described_class.new.perform(PayoutProcessorType::STRIPE, ["AchAccount", "CardBankAccount"])
      end
    end

    it "retries on failure instead of dead-lettering immediately" do
      expect(described_class.get_sidekiq_options["retry"]).to eq(3)
    end
  end

  describe "sidekiq_retries_exhausted" do
    it "notifies Sentry and emails accounting when retries are exhausted" do
      job = { "args" => [PayoutProcessorType::STRIPE, ["AchAccount"]], "error_message" => "timeout" }
      exception = ActiveRecord::StatementTimeout.new("Mysql2::Error: maximum statement execution time exceeded")

      mailer_double = double("mailer")
      expect(AccountingMailer).to receive(:payout_batch_failed)
        .with(PayoutProcessorType::STRIPE, ["AchAccount"], "ActiveRecord::StatementTimeout", exception.message)
        .and_return(mailer_double)
      expect(mailer_double).to receive(:deliver_later)
      expect(ErrorNotifier).to receive(:notify)
        .with(exception, payout_processor_type: PayoutProcessorType::STRIPE, bank_account_types: ["AchAccount"])

      described_class.sidekiq_retries_exhausted_block.call(job, exception)
    end
  end
end
