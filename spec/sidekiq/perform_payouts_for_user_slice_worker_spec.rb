# frozen_string_literal: true

describe PerformPayoutsForUserSliceWorker do
  let(:payout_date) { Date.yesterday }
  let(:user_ids) { [1, 2, 3] }

  describe "perform" do
    it "evaluates the given slice of sellers and enqueues their payouts" do
      expect(Payouts).to receive(:create_payments_for_balances_up_to_date_for_user_ids)
        .with(payout_date, PayoutProcessorType::PAYPAL, user_ids, bank_account_type: nil)

      described_class.new.perform(PayoutProcessorType::PAYPAL, payout_date.to_s, user_ids)
    end

    it "passes the bank account type through for the bank-rail runs" do
      expect(Payouts).to receive(:create_payments_for_balances_up_to_date_for_user_ids)
        .with(payout_date, PayoutProcessorType::STRIPE, user_ids, bank_account_type: "AchAccount")

      described_class.new.perform(PayoutProcessorType::STRIPE, payout_date.to_s, user_ids, "AchAccount")
    end

    it "does nothing when the slice is empty" do
      expect(Payouts).not_to receive(:create_payments_for_balances_up_to_date_for_user_ids)

      described_class.new.perform(PayoutProcessorType::PAYPAL, payout_date.to_s, [])
    end

    it "raises the per-slice statement budget above the default cap" do
      # Eligibility checks run several queries per seller inside the contended batch
      # window, which is well past the 5-minute default in config/database.yml.
      expect(WithMaxExecutionTime).to receive(:timeout_queries).with(seconds: described_class::QUERY_TIME_BUDGET).and_call_original
      allow(Payouts).to receive(:create_payments_for_balances_up_to_date_for_user_ids)

      described_class.new.perform(PayoutProcessorType::PAYPAL, payout_date.to_s, user_ids)
    end

    it "retries the slice rather than dead-lettering it on the first failure" do
      expect(described_class.get_sidekiq_options["retry"]).to eq(3)
    end

    describe "the in-flight deploy-freeze flag" do
      before { $redis.del(RedisKey.payout_batch_in_flight) }
      after  { $redis.del(RedisKey.payout_batch_in_flight) }

      it "is held while the slice runs so a deploy cannot recycle it mid-slice" do
        expect(Payouts).to receive(:create_payments_for_balances_up_to_date_for_user_ids) do
          expect($redis.zcard(RedisKey.payout_batch_in_flight)).to be > 0
        end

        described_class.new.perform(PayoutProcessorType::PAYPAL, payout_date.to_s, user_ids)

        expect($redis.zcard(RedisKey.payout_batch_in_flight)).to eq(0)
      end

      it "is cleared even when the slice raises" do
        expect(Payouts).to receive(:create_payments_for_balances_up_to_date_for_user_ids).and_raise(ActiveRecord::StatementTimeout)

        expect do
          described_class.new.perform(PayoutProcessorType::PAYPAL, payout_date.to_s, user_ids)
        end.to raise_error(ActiveRecord::StatementTimeout)

        expect($redis.zcard(RedisKey.payout_batch_in_flight)).to eq(0)
      end

      it "leaves a concurrent slice's entry alone" do
        $redis.zadd(RedisKey.payout_batch_in_flight, Time.current.to_i, "sibling-slice-token")
        allow(Payouts).to receive(:create_payments_for_balances_up_to_date_for_user_ids)

        described_class.new.perform(PayoutProcessorType::PAYPAL, payout_date.to_s, user_ids)

        expect($redis.zscore(RedisKey.payout_batch_in_flight, "sibling-slice-token")).to be_present
      end
    end
  end

  describe "sidekiq_retries_exhausted" do
    it "notifies Sentry and emails accounting so an unpaid slice cannot go unnoticed" do
      job = { "args" => [PayoutProcessorType::STRIPE, payout_date.to_s, user_ids, "AchAccount"] }
      exception = ActiveRecord::StatementTimeout.new("Mysql2::Error: maximum statement execution time exceeded")

      mailer_double = double("mailer")
      expect(AccountingMailer).to receive(:payout_batch_failed)
        .with(PayoutProcessorType::STRIPE, "AchAccount", "ActiveRecord::StatementTimeout", exception.message)
        .and_return(mailer_double)
      expect(mailer_double).to receive(:deliver_later)
      expect(ErrorNotifier).to receive(:notify)
        .with(exception, payout_processor_type: PayoutProcessorType::STRIPE, bank_account_type: "AchAccount", user_ids_count: user_ids.size)

      described_class.sidekiq_retries_exhausted_block.call(job, exception)
    end
  end
end
