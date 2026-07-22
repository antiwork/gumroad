# frozen_string_literal: true

describe PerformPayoutsUpToDelayDaysAgoWorker do
  describe "perform" do
    let(:payout_period_end_date) { User::PayoutSchedule.next_scheduled_payout_end_date }
    let(:payout_processor_type) { PayoutProcessorType::PAYPAL }

    it "calls 'create_payments_for_balances_up_to_date' on 'Payouts' which will do all the work" do
      expect(Payouts).to receive(:create_payments_for_balances_up_to_date).with(payout_period_end_date, payout_processor_type)
      described_class.new.perform(payout_processor_type)
    end

    describe "the in-flight deploy-freeze flag" do
      before { $redis.del(RedisKey.payout_batch_in_flight) }
      after  { $redis.del(RedisKey.payout_batch_in_flight) }

      it "is set (with a TTL safety net) while the batch runs and cleared afterwards" do
        expect(Payouts).to receive(:create_payments_for_balances_up_to_date) do
          expect($redis.get(RedisKey.payout_batch_in_flight).to_i).to be > 0
          expect($redis.ttl(RedisKey.payout_batch_in_flight)).to be_between(1, 3.hours.to_i)
        end

        described_class.new.perform(payout_processor_type)

        expect($redis.get(RedisKey.payout_batch_in_flight).to_i).to eq(0)
      end

      it "is cleared even when the batch raises" do
        expect(Payouts).to receive(:create_payments_for_balances_up_to_date).and_raise(ActiveRecord::StatementTimeout)

        expect do
          described_class.new.perform(payout_processor_type)
        end.to raise_error(ActiveRecord::StatementTimeout)

        expect($redis.get(RedisKey.payout_batch_in_flight).to_i).to eq(0)
      end

      it "stays up until the last concurrent per-type job finishes" do
        expect(Payouts).to receive(:create_payments_for_balances_up_to_date_for_bank_account_types) do
          # Simulate a sibling per-type job still running alongside this one.
          expect($redis.get(RedisKey.payout_batch_in_flight).to_i).to be >= 2
        end

        $redis.incr(RedisKey.payout_batch_in_flight) # the sibling
        described_class.new.perform(PayoutProcessorType::STRIPE, ["AchAccount"])

        # This job's decrement leaves the sibling's count in place.
        expect($redis.get(RedisKey.payout_batch_in_flight).to_i).to eq(1)
      end

      it "is not touched by the fan-out dispatcher itself" do
        allow(described_class).to receive(:perform_async)

        described_class.new.perform(PayoutProcessorType::STRIPE, ["AchAccount", "UkBankAccount"])

        expect($redis.get(RedisKey.payout_batch_in_flight).to_i).to eq(0)
      end

      it "raises the flag and applies the TTL as one atomic operation" do
        # The INCR and EXPIRE must land together — a positive counter with no TTL
        # would hold deploys until someone deleted the key by hand.
        expect(Payouts).to receive(:create_payments_for_balances_up_to_date) do
          expect($redis.ttl(RedisKey.payout_batch_in_flight)).to be > 0
        end

        described_class.new.perform(payout_processor_type)
      end

      it "does not decrement a count it never added when raising the flag fails" do
        # Simulate a sibling job's count already present, then a transient Redis error
        # while this job raises the flag. The ensure must not decrement the sibling's
        # count (that would falsely report the batch as finished).
        $redis.incr(RedisKey.payout_batch_in_flight)

        allow($redis).to receive(:eval).and_call_original
        expect($redis).to receive(:eval)
          .with(described_class::RAISE_IN_FLIGHT_FLAG_SCRIPT, any_args)
          .and_raise(Redis::TimeoutError)

        expect do
          described_class.new.perform(payout_processor_type)
        end.to raise_error(Redis::TimeoutError)

        expect($redis.get(RedisKey.payout_batch_in_flight).to_i).to eq(1)
      end

      it "cleans up a stray negative counter instead of leaving it behind" do
        # A negative value should never survive a job finishing — left in place it
        # would silently absorb a future batch's increment back to zero.
        expect(Payouts).to receive(:create_payments_for_balances_up_to_date)

        $redis.set(RedisKey.payout_batch_in_flight, -1)
        described_class.new.perform(payout_processor_type)

        expect($redis.exists?(RedisKey.payout_batch_in_flight)).to eq(false)
      end
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
