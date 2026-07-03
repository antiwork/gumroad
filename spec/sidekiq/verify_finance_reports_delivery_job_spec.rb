# frozen_string_literal: true

describe VerifyFinanceReportsDeliveryJob do
  before do
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(AccountingMailer).to receive(:finance_report_delivery_backstop_triggered).and_return(double("mailer", deliver_later: true))
    $redis.del(described_class::ACTIVE_SINCE_REDIS_KEY)
  end

  def activate_backstop(at:)
    $redis.set(described_class::ACTIVE_SINCE_REDIS_KEY, at.to_i)
  end

  def record_completion_for_fire(class_name, fire_time, at:)
    args = described_class::VERIFIED_JOBS[class_name].call(fire_time)
    FinanceReportCompletionTracking.record_completion(class_name, args, at:)
  end

  def clear_completion_for_fire(class_name, fire_time)
    args = described_class::VERIFIED_JOBS[class_name].call(fire_time)
    $redis.del(FinanceReportCompletionTracking.redis_key(class_name, args))
  end

  # 2026-07-01 was a monthly fire day (11:00 UTC); backstop runs at 18:00 UTC.
  let(:backstop_run_time) { Time.utc(2026, 7, 1, 18) }
  let(:monthly_fire) { Time.utc(2026, 7, 1, 11) }
  let(:taxjar_fire) { Time.utc(2026, 7, 1, 3) }

  def record_all_completions(now)
    described_class::VERIFIED_JOBS.each_key do |class_name|
      entry = YAML.load_file(Rails.root.join("config", "sidekiq_schedule.yml")).values.find { _1["class"] == class_name }
      fire_time = Fugit::Cron.parse("#{entry['cron'].sub(/#.*/, '').strip} UTC").previous_time(now - described_class::GRACE_PERIOD).to_t.utc
      record_completion_for_fire(class_name, fire_time, at: now)
    end
  end

  it "records a baseline and checks nothing on its first ever run" do
    travel_to(backstop_run_time) do
      described_class.new.perform

      expect($redis.get(described_class::ACTIVE_SINCE_REDIS_KEY)).to eq(backstop_run_time.to_i.to_s)
      expect(SendFinancesReportWorker.jobs).to be_empty
      expect(UploadUsStatesSalesTaxToTaxjarJob.jobs).to be_empty
      expect(AccountingMailer).not_to have_received(:finance_report_delivery_backstop_triggered)
    end
  end

  it "skips fires that predate activation instead of replaying already-completed history" do
    travel_to(backstop_run_time) do
      # Activated after today's fires: nothing recorded completions, but nothing alerts.
      activate_backstop(at: Time.utc(2026, 7, 1, 17))

      described_class.new.perform

      expect(SendFinancesReportWorker.jobs).to be_empty
      expect(AccountingMailer).not_to have_received(:finance_report_delivery_backstop_triggered)
    end
  end

  it "re-enqueues a monthly job whose scheduled run never completed, with the period pinned to the missed run" do
    travel_to(backstop_run_time) do
      activate_backstop(at: Time.utc(2026, 6, 25))
      record_all_completions(backstop_run_time)
      clear_completion_for_fire("SendFinancesReportWorker", monthly_fire)

      described_class.new.perform

      expect(SendFinancesReportWorker).to have_enqueued_sidekiq_job(6, 2026)
      expect(AccountingMailer).to have_received(:finance_report_delivery_backstop_triggered)
        .with("SendFinancesReportWorker", [6, 2026], monthly_fire, nil)
    end
  end

  it "re-enqueues the daily TaxJar upload with the day the missed run was for" do
    travel_to(backstop_run_time) do
      activate_backstop(at: Time.utc(2026, 6, 25))
      record_all_completions(backstop_run_time)
      clear_completion_for_fire("UploadUsStatesSalesTaxToTaxjarJob", taxjar_fire)

      described_class.new.perform

      # Fire was 03:00 UTC on 2026-07-01, which uploads the previous day's orders.
      expect(UploadUsStatesSalesTaxToTaxjarJob).to have_enqueued_sidekiq_job("2026-06-30")
    end
  end

  it "is not fooled by a manual re-run for a different period completing after the fire" do
    travel_to(backstop_run_time) do
      activate_backstop(at: Time.utc(2026, 6, 25))
      record_all_completions(backstop_run_time)
      clear_completion_for_fire("UploadUsStatesSalesTaxToTaxjarJob", taxjar_fire)
      # A manual re-push of an OLD day completed after today's fire — different period key.
      FinanceReportCompletionTracking.record_completion(
        "UploadUsStatesSalesTaxToTaxjarJob", ["2026-06-15"], at: Time.utc(2026, 7, 1, 12)
      )

      described_class.new.perform

      expect(UploadUsStatesSalesTaxToTaxjarJob).to have_enqueued_sidekiq_job("2026-06-30")
    end
  end

  it "does nothing when every job completed after its scheduled fire time" do
    travel_to(backstop_run_time) do
      activate_backstop(at: Time.utc(2026, 6, 25))
      record_all_completions(backstop_run_time)

      described_class.new.perform

      expect(SendFinancesReportWorker.jobs).to be_empty
      expect(UploadUsStatesSalesTaxToTaxjarJob.jobs).to be_empty
      expect(AccountingMailer).not_to have_received(:finance_report_delivery_backstop_triggered)
    end
  end

  it "flags a stale completion from before the scheduled fire time" do
    travel_to(backstop_run_time) do
      activate_backstop(at: Time.utc(2026, 6, 25))
      record_all_completions(backstop_run_time)
      record_completion_for_fire("SendDeferredRefundsReportWorker", monthly_fire, at: Time.utc(2026, 7, 1, 10))

      described_class.new.perform

      expect(SendDeferredRefundsReportWorker).to have_enqueued_sidekiq_job(6, 2026)
      expect(AccountingMailer).to have_received(:finance_report_delivery_backstop_triggered)
        .with("SendDeferredRefundsReportWorker", [6, 2026], monthly_fire, Time.utc(2026, 7, 1, 10))
    end
  end

  it "still flags a missed fire when the verifier itself is delayed for days (no age-out)" do
    # The monthly fire on July 1 was missed and the verifier didn't run until July 3 —
    # the miss must still be caught, not aged out of a lookback window.
    travel_to(Time.utc(2026, 7, 3, 18)) do
      activate_backstop(at: Time.utc(2026, 6, 25))
      record_all_completions(Time.utc(2026, 7, 3, 18))
      clear_completion_for_fire("SendFinancesReportWorker", monthly_fire)

      described_class.new.perform

      expect(SendFinancesReportWorker).to have_enqueued_sidekiq_job(6, 2026)
      expect(AccountingMailer).to have_received(:finance_report_delivery_backstop_triggered)
        .with("SendFinancesReportWorker", [6, 2026], monthly_fire, nil)
    end
  end

  it "does not re-flag old completed fires mid-month" do
    # Mid-month, every job's most recent fire has a completion recorded — nothing alerts.
    travel_to(Time.utc(2026, 7, 15, 18)) do
      activate_backstop(at: Time.utc(2026, 6, 25))
      record_all_completions(Time.utc(2026, 7, 15, 18))

      described_class.new.perform

      expect(SendFinancesReportWorker.jobs).to be_empty
      expect(GenerateFinancialReportsForPreviousMonthJob.jobs).to be_empty
      expect(AccountingMailer).not_to have_received(:finance_report_delivery_backstop_triggered)
    end
  end

  it "alerts and keeps verifying the remaining jobs when a re-enqueue raises (e.g. a pending-rerun lock conflict)" do
    travel_to(backstop_run_time) do
      activate_backstop(at: Time.utc(2026, 6, 25))
      record_all_completions(backstop_run_time)
      clear_completion_for_fire("SendFinancesReportWorker", monthly_fire)
      clear_completion_for_fire("UploadUsStatesSalesTaxToTaxjarJob", taxjar_fire)
      # SendFinancesReportWorker's rerun conflicts with one still pending from yesterday.
      allow(SendFinancesReportWorker).to receive(:perform_async).and_raise(RuntimeError, "lock conflict")

      described_class.new.perform

      # The gap is still alerted even though the re-enqueue was refused...
      expect(AccountingMailer).to have_received(:finance_report_delivery_backstop_triggered)
        .with("SendFinancesReportWorker", [6, 2026], monthly_fire, nil)
      # ...and the loop went on to check (and fix) the remaining jobs.
      expect(UploadUsStatesSalesTaxToTaxjarJob).to have_enqueued_sidekiq_job("2026-06-30")
    end
  end

  it "leaves a recent fire inside the grace period unchecked" do
    # At 08:00 UTC the 03:00 TaxJar fire is only 5h old (< 6h grace): the checked fire is
    # yesterday's, which completed — so a still-running today's job isn't flagged.
    travel_to(Time.utc(2026, 7, 15, 8)) do
      activate_backstop(at: Time.utc(2026, 6, 25))
      # Every job's CHECKED fire (the last one older than the grace period) completed —
      # for TaxJar that's yesterday's 03:00 fire; today's 03:00 fire has no completion
      # but is inside the grace period, so it isn't checked.
      record_all_completions(Time.utc(2026, 7, 15, 8))

      described_class.new.perform

      expect(UploadUsStatesSalesTaxToTaxjarJob.jobs).to be_empty
      expect(AccountingMailer).not_to have_received(:finance_report_delivery_backstop_triggered)
    end
  end

  it "re-enqueues the quarterly orchestrator with the quarter the missed run was for" do
    # Quarterly fire: 10:00 UTC on July 2nd.
    travel_to(Time.utc(2026, 7, 2, 18)) do
      activate_backstop(at: Time.utc(2026, 6, 25))
      record_all_completions(Time.utc(2026, 7, 2, 18))
      clear_completion_for_fire("GenerateFinancialReportsForPreviousQuarterJob", Time.utc(2026, 7, 2, 10))

      described_class.new.perform

      expect(GenerateFinancialReportsForPreviousQuarterJob).to have_enqueued_sidekiq_job(2, 2026)
    end
  end

  it "verifies every scheduler-fired job in VERIFIED_JOBS exists in the schedule and records completions" do
    schedule_classes = YAML.load_file(Rails.root.join("config", "sidekiq_schedule.yml")).values.map { _1["class"] }
    described_class::VERIFIED_JOBS.each_key do |class_name|
      expect(schedule_classes).to include(class_name), "#{class_name} is verified but not in sidekiq_schedule.yml"
      expect(class_name.constantize.ancestors).to include(FinanceReportCompletionTracking),
                                                  "#{class_name} is verified but does not record completions"
    end
  end

  it "resolves the same period key at completion time as the verifier does for the fire" do
    # A scheduled no-arg run completes shortly after its fire; the tracking key it writes
    # must be the one the verifier reads for that fire, for every verified job.
    described_class::VERIFIED_JOBS.each do |class_name, args_builder|
      klass = class_name.constantize
      fire_args = args_builder.call(monthly_fire)
      completion_args =
        if klass.respond_to?(:default_alert_args)
          travel_to(monthly_fire + 5.minutes) { klass.default_alert_args }
        else
          []
        end

      expect(completion_args).to eq(fire_args),
                                 "#{class_name}: completion key #{completion_args.inspect} != verifier key #{fire_args.inspect}"
    end
  end
end
