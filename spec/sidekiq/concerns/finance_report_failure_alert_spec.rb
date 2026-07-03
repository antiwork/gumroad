# frozen_string_literal: true

describe FinanceReportFailureAlert do
  let(:exception) { ActiveRecord::StatementTimeout.new("Query exceeded max execution time") }
  let(:mailer) { double("mailer") }

  it "emails a retry-exhaustion alert with the job's args" do
    expect(AccountingMailer).to receive(:finance_report_job_failed)
      .with("CreateVatReportJob", [2, 2026], "ActiveRecord::StatementTimeout", "Query exceeded max execution time")
      .and_return(mailer)
    expect(mailer).to receive(:deliver_later)

    job = { "class" => "CreateVatReportJob", "args" => [2, 2026] }
    CreateVatReportJob.sidekiq_retries_exhausted_block.call(job, exception)
  end

  it "pins the resolved default period when the scheduler fired the job with no args" do
    travel_to(Time.utc(2026, 7, 1, 11)) do
      expect(AccountingMailer).to receive(:finance_report_job_failed)
        .with("SendFinancesReportWorker", [6, 2026], "ActiveRecord::StatementTimeout", "Query exceeded max execution time")
        .and_return(mailer)
      expect(mailer).to receive(:deliver_later)

      job = { "class" => "SendFinancesReportWorker", "args" => [] }
      SendFinancesReportWorker.sidekiq_retries_exhausted_block.call(job, exception)
    end
  end

  it "resolves the default period from the job's created_at, not the alert time" do
    # Scheduled June 1 for May's report; retries exhaust after the month boundary on July 1.
    # The alert must still point at May, not re-resolve "last month" as June.
    travel_to(Time.utc(2026, 7, 1, 11)) do
      expect(AccountingMailer).to receive(:finance_report_job_failed)
        .with("SendFinancesReportWorker", [5, 2026], "ActiveRecord::StatementTimeout", "Query exceeded max execution time")
        .and_return(mailer)
      expect(mailer).to receive(:deliver_later)

      job = { "class" => "SendFinancesReportWorker", "args" => [], "created_at" => Time.utc(2026, 6, 1, 6).to_f }
      SendFinancesReportWorker.sidekiq_retries_exhausted_block.call(job, exception)
    end
  end

  it "passes empty args for jobs without reporting-period arguments" do
    expect(AccountingMailer).to receive(:finance_report_job_failed)
      .with("SendStripeCurrencyBalancesReportJob", [], "ActiveRecord::StatementTimeout", "Query exceeded max execution time")
      .and_return(mailer)
    expect(mailer).to receive(:deliver_later)

    job = { "class" => "SendStripeCurrencyBalancesReportJob", "args" => [] }
    SendStripeCurrencyBalancesReportJob.sidekiq_retries_exhausted_block.call(job, exception)
  end

  it "is included in every finance report job" do
    [
      SendFinancesReportWorker,
      SendDeferredRefundsReportWorker,
      SendStripeCurrencyBalancesReportJob,
      EmailOutstandingBalancesCsvWorker,
      CreateCanadaMonthlySalesReportJob,
      GenerateCanadaSalesReportJob,
      GenerateFeesByCreatorLocationReportJob,
      CreateIndiaSalesReportJob,
      CreateVatReportJob,
      GenerateSalesReportJob,
      GenerateFinancialReportsForPreviousMonthJob,
      GenerateFinancialReportsForPreviousQuarterJob,
    ].each do |job_class|
      expect(job_class.ancestors).to include(FinanceReportFailureAlert), "#{job_class} is missing FinanceReportFailureAlert"
      expect(job_class.sidekiq_retries_exhausted_block).to be_present
    end
  end
end
