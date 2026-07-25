# frozen_string_literal: true

describe HoldsDeployWhileRunning do
  let(:key) { RedisKey.jobs_holding_deploys }

  before { $redis.del(key) }
  after  { $redis.del(key) }

  describe ".while_holding_deploys" do
    it "registers an entry with a TTL while the block runs and clears it afterwards" do
      described_class.while_holding_deploys do
        expect($redis.zcard(key)).to eq(1)
        expect($redis.ttl(key)).to be_between(1, described_class::IN_FLIGHT_ENTRY_TTL.to_i)
      end

      expect($redis.zcard(key)).to eq(0)
    end

    it "clears its entry even when the block raises" do
      expect do
        described_class.while_holding_deploys { raise ActiveRecord::StatementTimeout }
      end.to raise_error(ActiveRecord::StatementTimeout)

      expect($redis.zcard(key)).to eq(0)
    end

    it "leaves a concurrent job's entry alone" do
      $redis.zadd(key, Time.current.to_i, "sibling-token")

      described_class.while_holding_deploys do
        expect($redis.zcard(key)).to eq(2)
      end

      expect($redis.zcard(key)).to eq(1)
      expect($redis.zscore(key, "sibling-token")).to be_present
    end

    it "cleans up its own entry when Redis ran the registration but the response was lost" do
      # The ambiguous-outcome case. Because cleanup removes this job's own token
      # unconditionally, the entry can't go stale and stall deploys for hours.
      allow($redis).to receive(:eval).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs) # Redis DID run the script...
        raise Redis::TimeoutError # ...but the response never came back.
      end

      expect do
        described_class.while_holding_deploys { raise "block should not run" }
      end.to raise_error(Redis::TimeoutError)

      expect($redis.zcard(key)).to eq(0)
    end

    it "does not let a cleanup failure mask the block's outcome" do
      allow($redis).to receive(:zrem).and_raise(Redis::CannotConnectError)
      expect(ErrorNotifier).to receive(:notify).with(instance_of(Redis::CannotConnectError), redis_key: key)

      expect { described_class.while_holding_deploys { :done } }.not_to raise_error
    end
  end

  describe HoldsDeployWhileRunning::ForWholePerform do
    let(:job_class) do
      Class.new do
        include Sidekiq::Job
        include HoldsDeployWhileRunning::ForWholePerform

        def self.name = "DeployHoldingTestJob"

        attr_reader :seen_in_flight

        def perform(*args)
          @seen_in_flight = $redis.zcard(RedisKey.jobs_holding_deploys)
          args
        end
      end
    end

    it "holds deploys for the whole of #perform and releases afterwards" do
      job = job_class.new

      expect(job.perform(1, 2)).to eq([1, 2])
      expect(job.seen_in_flight).to eq(1)
      expect($redis.zcard(key)).to eq(0)
    end

    it "releases the hold when #perform raises" do
      failing_class = Class.new(job_class) do
        def perform(*) = raise(ActiveRecord::StatementTimeout)
      end

      expect { failing_class.new.perform }.to raise_error(ActiveRecord::StatementTimeout)
      expect($redis.zcard(key)).to eq(0)
    end
  end

  it "is included in the jobs whose interruption the overnight deploy block used to prevent" do
    # These are the long-running scheduled jobs a deploy must not recycle mid-run. If a new
    # one is added, include the concern in it and list it here. This list is exhaustive on
    # purpose: everything including FinanceReportFailureAlert gets the wrapper through it, so
    # the report jobs below are listed individually rather than left implicit.
    [
      # Payout jobs — money movement.
      PerformPayoutsUpToDelayDaysAgoWorker,
      PerformPayoutsForUserSliceWorker,
      PerformDailyInstantPayoutsWorker,
      ExecuteScheduledPayoutsJob,
      # Tax upload.
      UploadUsStatesSalesTaxToTaxjarJob,
      # Report generators, via FinanceReportFailureAlert.
      GenerateCanadaSalesReportJob,
      GenerateFinancialReportsForPreviousMonthJob,
      GenerateFinancialReportsForPreviousQuarterJob,
      CreateIndiaSalesReportJob,
      CreateVatReportJob,
      GenerateSalesReportJob,
      SendFinancesReportWorker,
      CreateCanadaMonthlySalesReportJob,
      EmailOutstandingBalancesCsvWorker,
      GenerateFeesByCreatorLocationReportJob,
      SendDailyFinanceLedgerReportJob,
      SendDeferredRefundsReportWorker,
      SendStripeBalanceSummariesReportJob,
      SendStripeCurrencyBalancesReportJob,
    ].each do |job_class|
      expect(job_class.ancestors).to include(described_class), "#{job_class} is missing HoldsDeployWhileRunning"
    end
  end
end
