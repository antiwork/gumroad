# frozen_string_literal: true

describe VerifyFinanceReportsDeliveryJob do
  before do
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(AccountingMailer).to receive(:finance_report_delivery_backstop_triggered).and_return(double("mailer", deliver_later: true))
    described_class::VERIFIED_JOBS.each_key do |class_name|
      $redis.del(FinanceReportCompletionTracking.redis_key(class_name))
    end
  end

  def record_completion(class_name, at:)
    $redis.set(FinanceReportCompletionTracking.redis_key(class_name), at.to_i)
  end

  # 2026-07-01 was a monthly fire day (11:00 UTC); backstop runs at 18:00 UTC.
  let(:backstop_run_time) { Time.utc(2026, 7, 1, 18) }

  it "re-enqueues a monthly job whose scheduled run never completed, with the period pinned to the missed run" do
    travel_to(backstop_run_time) do
      described_class::VERIFIED_JOBS.each_key { |name| record_completion(name, at: Time.current) }
      $redis.del(FinanceReportCompletionTracking.redis_key("SendFinancesReportWorker"))

      described_class.new.perform

      expect(SendFinancesReportWorker).to have_enqueued_sidekiq_job(6, 2026)
      expect(AccountingMailer).to have_received(:finance_report_delivery_backstop_triggered)
        .with("SendFinancesReportWorker", [6, 2026], Time.utc(2026, 7, 1, 11), nil)
    end
  end

  it "re-enqueues the daily TaxJar upload with the day the missed run was for" do
    travel_to(backstop_run_time) do
      described_class::VERIFIED_JOBS.each_key { |name| record_completion(name, at: Time.current) }
      $redis.del(FinanceReportCompletionTracking.redis_key("UploadUsStatesSalesTaxToTaxjarJob"))

      described_class.new.perform

      # Fire was 03:00 UTC on 2026-07-01, which uploads the previous day's orders.
      expect(UploadUsStatesSalesTaxToTaxjarJob).to have_enqueued_sidekiq_job("2026-06-30")
    end
  end

  it "does nothing when every job completed after its scheduled fire time" do
    travel_to(backstop_run_time) do
      described_class::VERIFIED_JOBS.each_key { |name| record_completion(name, at: Time.current) }

      described_class.new.perform

      expect(SendFinancesReportWorker.jobs).to be_empty
      expect(UploadUsStatesSalesTaxToTaxjarJob.jobs).to be_empty
      expect(AccountingMailer).not_to have_received(:finance_report_delivery_backstop_triggered)
    end
  end

  it "flags a stale completion from before the scheduled fire time" do
    travel_to(backstop_run_time) do
      described_class::VERIFIED_JOBS.each_key { |name| record_completion(name, at: Time.current) }
      record_completion("SendDeferredRefundsReportWorker", at: Time.utc(2026, 6, 1, 11, 5))

      described_class.new.perform

      expect(SendDeferredRefundsReportWorker).to have_enqueued_sidekiq_job(6, 2026)
      expect(AccountingMailer).to have_received(:finance_report_delivery_backstop_triggered)
        .with("SendDeferredRefundsReportWorker", [6, 2026], Time.utc(2026, 7, 1, 11), Time.utc(2026, 6, 1, 11, 5))
    end
  end

  it "skips fires older than the lookback window instead of alerting on missing history" do
    # Mid-month: the last monthly fire (June 1) is far outside the 48h lookback; only the
    # daily TaxJar fire is within it.
    travel_to(Time.utc(2026, 7, 15, 18)) do
      record_completion("UploadUsStatesSalesTaxToTaxjarJob", at: Time.current)

      described_class.new.perform

      expect(SendFinancesReportWorker.jobs).to be_empty
      expect(GenerateFinancialReportsForPreviousMonthJob.jobs).to be_empty
      expect(AccountingMailer).not_to have_received(:finance_report_delivery_backstop_triggered)
    end
  end

  it "leaves a recent fire inside the grace period unchecked" do
    # At 08:00 UTC the 03:00 TaxJar fire is only 5h old (< 6h grace): the checked fire is
    # yesterday's, which completed — so a still-running today's job isn't flagged.
    travel_to(Time.utc(2026, 7, 15, 8)) do
      record_completion("UploadUsStatesSalesTaxToTaxjarJob", at: Time.utc(2026, 7, 14, 3, 30))

      described_class.new.perform

      expect(UploadUsStatesSalesTaxToTaxjarJob.jobs).to be_empty
      expect(AccountingMailer).not_to have_received(:finance_report_delivery_backstop_triggered)
    end
  end

  it "re-enqueues the quarterly orchestrator with the quarter the missed run was for" do
    # Quarterly fire: 10:00 UTC on July 2nd.
    travel_to(Time.utc(2026, 7, 2, 18)) do
      described_class::VERIFIED_JOBS.each_key { |name| record_completion(name, at: Time.current) }
      $redis.del(FinanceReportCompletionTracking.redis_key("GenerateFinancialReportsForPreviousQuarterJob"))

      described_class.new.perform

      expect(GenerateFinancialReportsForPreviousQuarterJob).to have_enqueued_sidekiq_job(2, 2026)
    end
  end

  it "verifies every scheduler-fired job in VERIFIED_JOBS exists in the schedule" do
    schedule_classes = YAML.load_file(Rails.root.join("config", "sidekiq_schedule.yml")).values.map { _1["class"] }
    described_class::VERIFIED_JOBS.each_key do |class_name|
      expect(schedule_classes).to include(class_name), "#{class_name} is verified but not in sidekiq_schedule.yml"
      expect(class_name.constantize.ancestors).to include(FinanceReportCompletionTracking),
                                                  "#{class_name} is verified but does not record completions"
    end
  end
end
