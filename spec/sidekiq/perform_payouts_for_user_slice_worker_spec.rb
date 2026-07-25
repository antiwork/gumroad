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

    it "runs off the critical queue so a slow payout run cannot delay buyer-facing work" do
      # Several slices run concurrently, each holding a thread for tens of seconds of
      # eligibility queries. :critical is where purchase receipts live.
      expect(described_class.get_sidekiq_options["queue"]).to eq(:default)
    end

    describe "the in-flight deploy-freeze flag" do
      before { $redis.del(RedisKey.jobs_holding_deploys) }
      after  { $redis.del(RedisKey.jobs_holding_deploys) }

      it "is held while the slice runs so a deploy cannot recycle it mid-slice" do
        expect(Payouts).to receive(:create_payments_for_balances_up_to_date_for_user_ids) do
          expect($redis.zcard(RedisKey.jobs_holding_deploys)).to be > 0
        end

        described_class.new.perform(PayoutProcessorType::PAYPAL, payout_date.to_s, user_ids)

        expect($redis.zcard(RedisKey.jobs_holding_deploys)).to eq(0)
      end

      it "is cleared even when the slice raises" do
        expect(Payouts).to receive(:create_payments_for_balances_up_to_date_for_user_ids).and_raise(ActiveRecord::StatementTimeout)

        expect do
          described_class.new.perform(PayoutProcessorType::PAYPAL, payout_date.to_s, user_ids)
        end.to raise_error(ActiveRecord::StatementTimeout)

        expect($redis.zcard(RedisKey.jobs_holding_deploys)).to eq(0)
      end

      it "leaves a concurrent slice's entry alone" do
        $redis.zadd(RedisKey.jobs_holding_deploys, Time.current.to_i, "sibling-slice-token")
        allow(Payouts).to receive(:create_payments_for_balances_up_to_date_for_user_ids)

        described_class.new.perform(PayoutProcessorType::PAYPAL, payout_date.to_s, user_ids)

        expect($redis.zscore(RedisKey.jobs_holding_deploys, "sibling-slice-token")).to be_present
      end
    end
  end

  describe "sidekiq_retries_exhausted" do
    it "sends the slice-specific alert so the blast radius is not overstated" do
      job = { "args" => [PayoutProcessorType::STRIPE, payout_date.to_s, user_ids, "AchAccount"] }
      exception = ActiveRecord::StatementTimeout.new("Mysql2::Error: maximum statement execution time exceeded")

      mailer_double = double("mailer")
      # Deliberately NOT payout_batch_failed: that email claims the whole processor bucket is
      # unpaid and prescribes a cohort-wide re-run, which would duplicate payout notes for
      # every ineligible seller.
      expect(AccountingMailer).not_to receive(:payout_batch_failed)
      expect(AccountingMailer).to receive(:payout_batch_slice_failed)
        .with(PayoutProcessorType::STRIPE, "AchAccount", user_ids.size, "ActiveRecord::StatementTimeout", exception.message)
        .and_return(mailer_double)
      expect(mailer_double).to receive(:deliver_later)
      expect(ErrorNotifier).to receive(:notify)
        .with(exception, payout_processor_type: PayoutProcessorType::STRIPE, bank_account_type: "AchAccount", user_ids_count: user_ids.size)

      described_class.sidekiq_retries_exhausted_block.call(job, exception)
    end
  end
end
