# frozen_string_literal: true

describe StripeBalanceSummariesReport do
  let(:balance_csv) do
    <<~CSV
      category,description,net_amount,currency
      starting_balance,Starting balance (2026-06-01),100000.00,usd
      ending_balance,Ending balance (2026-07-01),120000.00,usd
    CSV
  end

  let(:activity_csv) do
    <<~CSV
      reporting_category,currency,count,gross,fee,net
      charge,usd,10,5000.00,0.00,5000.00
      refund,usd,2,-300.00,-10.00,-310.00
      total,usd,12,4700.00,-10.00,4690.00
    CSV
  end

  let(:payouts_csv) do
    <<~CSV
      reporting_category,currency,count,gross,fee,net
      payout,usd,4,-2000.00,0.00,-2000.00
      total,usd,4,-2000.00,0.00,-2000.00
    CSV
  end

  describe ".generate" do
    before do
      allow(GlobalConfig).to receive(:get).and_call_original
      allow(GlobalConfig).to receive(:get).with("STRIPE_API_KEY_FLEXILE").and_return("rk_live_flexile")
      allow(GlobalConfig).to receive(:get).with("STRIPE_API_KEY_HELPER").and_return(nil)
      allow(GlobalConfig).to receive(:get).with("STRIPE_API_KEY_IFFY").and_return(nil)

      allow(described_class).to receive(:run_report) do |api_key:, report_type:, **|
        case report_type
        when "balance.summary.1" then balance_csv
        when "balance_change_from_activity.summary.1" then activity_csv
        when "payouts.summary.1" then payouts_csv
        end
      end
    end

    it "builds one combined CSV per configured entity and lists unconfigured entities as skipped" do
      result = described_class.generate(6, 2026)

      expect(result[:csvs].keys).to eq(["Gumroad", "Flexile"])
      expect(result[:skipped]).to eq(["Helper", "Iffy"])

      rows = CSV.parse(result[:csvs]["Gumroad"])
      expect(rows.first).to eq(%w[Section Description Count Amount Currency])
      expect(rows).to include(["Balance Summary", "Starting balance (2026-06-01)", nil, "100000.00", "usd"])
      expect(rows).to include(["Balance Change from Activity", "Charges", "10", "5000.00", "usd"])
      expect(rows).to include(["Payouts", "Total paid out", "4", "-2000.00", "usd"])
    end

    it "requests the month's UTC boundaries, filtering Gumroad to USD and leaving the others unfiltered" do
      described_class.generate(6, 2026)

      expect(described_class).to have_received(:run_report)
        .with(api_key: STRIPE_SECRET, report_type: "balance.summary.1",
              interval_start: Time.utc(2026, 6, 1).to_i, interval_end: Time.utc(2026, 7, 1).to_i, usd_only: true)
      expect(described_class).to have_received(:run_report)
        .with(api_key: "rk_live_flexile", report_type: "balance.summary.1",
              interval_start: Time.utc(2026, 6, 1).to_i, interval_end: Time.utc(2026, 7, 1).to_i, usd_only: false)
    end
  end

  describe ".build_combined_csv" do
    it "splits activity categories with fees into a gross line plus an indented fee sub-line" do
      csv = described_class.build_combined_csv(
        "balance.summary.1" => balance_csv,
        "balance_change_from_activity.summary.1" => activity_csv,
        "payouts.summary.1" => payouts_csv,
      )

      rows = CSV.parse(csv)
      refund_index = rows.index { |row| row[1] == "Refunds" }
      expect(rows[refund_index]).to eq(["Balance Change from Activity", "Refunds", "2", "-300.00", "usd"])
      expect(rows[refund_index + 1]).to eq(["Balance Change from Activity", "  Fees (Refunds)", nil, "-10.00", "usd"])
    end

    it "keeps the activity total as a single net line even though it carries the summed fees" do
      csv = described_class.build_combined_csv(
        "balance.summary.1" => balance_csv,
        "balance_change_from_activity.summary.1" => activity_csv,
        "payouts.summary.1" => payouts_csv,
      )

      rows = CSV.parse(csv)
      expect(rows).to include(["Balance Change from Activity", "Net balance change from activity", "12", "4690.00", "usd"])
      expect(rows.none? { |row| row[1] == "  Fees (Net balance change from activity)" }).to eq(true)
    end
  end

  describe ".run_report" do
    it "creates the report run, polls until it succeeds, and downloads the result" do
      pending_run = double("run", id: "frr_123", status: "pending")
      succeeded_run = double("run", id: "frr_123", status: "succeeded", result: double("file", url: "https://files.stripe.com/v1/files/file_123/contents"))

      expect(Stripe::Reporting::ReportRun).to receive(:create)
        .with({ report_type: "balance.summary.1",
                parameters: { interval_start: 1, interval_end: 2, timezone: "Etc/UTC", currency: "usd" } },
              { api_key: "rk_live_test" })
        .and_return(pending_run)
      expect(Stripe::Reporting::ReportRun).to receive(:retrieve).with("frr_123", { api_key: "rk_live_test" }).and_return(succeeded_run)
      allow(described_class).to receive(:sleep)
      expect(described_class).to receive(:download_result).with("rk_live_test", "https://files.stripe.com/v1/files/file_123/contents").and_return("csv")

      expect(described_class.run_report(api_key: "rk_live_test", report_type: "balance.summary.1", interval_start: 1, interval_end: 2, usd_only: true)).to eq("csv")
    end

    it "raises when the report run fails" do
      failed_run = double("run", id: "frr_123", status: "failed", error: "boom")
      expect(Stripe::Reporting::ReportRun).to receive(:create).and_return(failed_run)

      expect do
        described_class.run_report(api_key: "rk_live_test", report_type: "balance.summary.1", interval_start: 1, interval_end: 2, usd_only: false)
      end.to raise_error(/failed: boom/)
    end
  end
end
