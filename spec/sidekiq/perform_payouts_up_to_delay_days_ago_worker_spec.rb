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
          expect($redis.zcard(RedisKey.payout_batch_in_flight)).to be > 0
          expect($redis.ttl(RedisKey.payout_batch_in_flight)).to be_between(1, 3.hours.to_i)
        end

        described_class.new.perform(payout_processor_type)

        expect($redis.zcard(RedisKey.payout_batch_in_flight)).to eq(0)
      end

      it "is cleared even when the batch raises" do
        expect(Payouts).to receive(:create_payments_for_balances_up_to_date).and_raise(ActiveRecord::StatementTimeout)

        expect do
          described_class.new.perform(payout_processor_type)
        end.to raise_error(ActiveRecord::StatementTimeout)

        expect($redis.zcard(RedisKey.payout_batch_in_flight)).to eq(0)
      end

      it "stays up until the last concurrent per-type job finishes" do
        expect(Payouts).to receive(:create_payments_for_balances_up_to_date_for_bank_account_types) do
          # Simulate a sibling per-type job still running alongside this one.
          expect($redis.zcard(RedisKey.payout_batch_in_flight)).to be >= 2
        end

        $redis.zadd(RedisKey.payout_batch_in_flight, Time.current.to_i, "sibling-token")
        described_class.new.perform(PayoutProcessorType::STRIPE, ["AchAccount"])

        # This job removes only its own token, leaving the sibling's entry in place.
        expect($redis.zcard(RedisKey.payout_batch_in_flight)).to eq(1)
        expect($redis.zscore(RedisKey.payout_batch_in_flight, "sibling-token")).to be_present
      end

      it "is not touched by the fan-out dispatcher itself" do
        allow(described_class).to receive(:perform_async)

        described_class.new.perform(PayoutProcessorType::STRIPE, ["AchAccount", "UkBankAccount"])

        expect($redis.zcard(RedisKey.payout_batch_in_flight)).to eq(0)
      end

      it "registers the token and applies the TTL as one atomic operation" do
        # The ZADD and EXPIRE must land together — a token in a key with no TTL would
        # have no crash backstop if the healthcheck-side score pruning ever regressed.
        expect(Payouts).to receive(:create_payments_for_balances_up_to_date) do
          expect($redis.ttl(RedisKey.payout_batch_in_flight)).to be > 0
        end

        described_class.new.perform(payout_processor_type)
      end

      it "never removes a sibling's entry when registering its own token fails" do
        # Simulate a sibling job's entry already present, then a transient Redis error
        # while this job registers. Cleanup removes only this job's token (a no-op if
        # it never landed), so the sibling's entry survives.
        $redis.zadd(RedisKey.payout_batch_in_flight, Time.current.to_i, "sibling-token")

        allow($redis).to receive(:eval).and_call_original
        expect($redis).to receive(:eval)
          .with(described_class::RAISE_IN_FLIGHT_FLAG_SCRIPT, any_args)
          .and_raise(Redis::TimeoutError)

        expect do
          described_class.new.perform(payout_processor_type)
        end.to raise_error(Redis::TimeoutError)

        expect($redis.zcard(RedisKey.payout_batch_in_flight)).to eq(1)
        expect($redis.zscore(RedisKey.payout_batch_in_flight, "sibling-token")).to be_present
      end

      it "cleans up its own entry even when Redis executed the registration but the response was lost" do
        # The ambiguous-outcome case: the registration script runs on the server but the
        # client sees an error. Because cleanup removes this job's own token
        # unconditionally, the entry cannot go stale and stall deploys for hours.
        registered_token = nil
        allow($redis).to receive(:eval).and_wrap_original do |original, *args, **kwargs|
          original.call(*args, **kwargs) # Redis DID execute the script...
          registered_token = kwargs[:argv][1]
          raise Redis::TimeoutError # ...but the response never made it back.
        end
        expect(Payouts).not_to receive(:create_payments_for_balances_up_to_date)

        expect do
          described_class.new.perform(payout_processor_type)
        end.to raise_error(Redis::TimeoutError)

        expect(registered_token).to be_present
        expect($redis.zcard(RedisKey.payout_batch_in_flight)).to eq(0)
      end

      it "does not let a cleanup failure mask the batch outcome" do
        # A dead Redis during the ensure would otherwise replace the batch's own
        # result; the entry self-heals via its TTL, so report and move on.
        expect(Payouts).to receive(:create_payments_for_balances_up_to_date)
        allow($redis).to receive(:zrem).and_raise(Redis::CannotConnectError)
        expect(ErrorNotifier).to receive(:notify).with(instance_of(Redis::CannotConnectError), redis_key: RedisKey.payout_batch_in_flight)

        expect do
          described_class.new.perform(payout_processor_type)
        end.not_to raise_error
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
