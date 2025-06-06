# frozen_string_literal: true

require "spec_helper"

describe Reports::GenerateYtdSalesReportJob do
  let(:job) { described_class.new }
  let(:es_results_double) { double("Elasticsearch::Persistence::Repository::Response::Results") }
  let(:mailer_double) { double("ActionMailer::MessageDelivery", deliver_now: true) }
  let(:recipient_emails) { ["test1@example.com", "test2@example.com"] }
  let(:redis_key) { RedisKey.ytd_sales_report_emails }

  before do
    allow(Purchase).to receive(:search).and_return(es_results_double)
    allow($redis).to receive(:lrange).with(redis_key, 0, -1).and_return(recipient_emails)
    allow(AccountingMailer).to receive(:ytd_sales_report).and_return(mailer_double)
  end

  describe "#perform" do
    context "when processing actual purchase records", :sidekiq_inline, :elasticsearch_wait_for_refresh do
      let(:csv_report_emails) { ["report_user1@example.com", "report_user2@example.com"] }

      before do
        recreate_model_index(Purchase)

        allow(Purchase).to receive(:search).and_call_original
        allow($redis).to receive(:lrange).with(redis_key, 0, -1).and_return(csv_report_emails)
        allow(AccountingMailer).to receive(:ytd_sales_report).and_return(mailer_double)

        travel_to Time.zone.local(2023, 8, 15) do
          create(:purchase, ip_country: "US", ip_state: "CA", price_cents: 10000, purchase_state: "successful", chargeback_date: nil, created_at: Time.zone.local(2023, 1, 15))
          create(:purchase, ip_country: "US", ip_state: "NY", price_cents: 5000, purchase_state: "successful", chargeback_date: nil, created_at: Time.zone.local(2023, 2, 10))
          create(:purchase, ip_country: "GB", ip_state: "London", price_cents: 7500, purchase_state: "preorder_concluded_successfully", chargeback_date: nil, created_at: Time.zone.local(2023, 3, 5))

          refunded_purchase_us_ca = create(:purchase, ip_country: "US", ip_state: "CA", price_cents: 2000, purchase_state: "successful", chargeback_date: nil, created_at: Time.zone.local(2023, 5, 1))
          create(:refund, purchase: refunded_purchase_us_ca, amount_cents: 1000)
          # Reindex the purchase to update the amount_refunded_cents field
          options = { "record_id" => refunded_purchase_us_ca.id, "class_name" => "Purchase" }
          ElasticsearchIndexerWorker.perform_async("index", options)

          create(:purchase, ip_country: "FR", ip_state: "Paris", price_cents: 2000, purchase_state: "successful", created_at: Time.zone.local(2022, 12, 20))
          create(:purchase, ip_country: "DE", ip_state: "Berlin", price_cents: 3000, purchase_state: "successful", chargeback_date: Time.zone.local(2023, 1, 20), chargeback_reversed: false, created_at: Time.zone.local(2023, 1, 18))
          create(:purchase, ip_country: "ES", ip_state: "Madrid", price_cents: 4000, purchase_state: "failed", created_at: Time.zone.local(2023, 4, 1))
        end
      end

      it "generates correct CSV data including refunds" do
        captured_csv_string = nil
        allow(AccountingMailer).to receive(:ytd_sales_report) do |csv_string, email|
          captured_csv_string = csv_string if email == csv_report_emails.first
          mailer_double
        end.and_return(mailer_double)

        travel_to Time.zone.local(2023, 8, 15) do
          job.perform
        end

        expect(captured_csv_string).not_to be_nil
        csv_data = CSV.parse(captured_csv_string, headers: true)
        parsed_rows = csv_data.map(&:to_h)

        expected_rows = [
          { "Country" => "US", "State" => "CA", "Net Sales (USD)" => "110.0" },
          { "Country" => "US", "State" => "NY", "Net Sales (USD)" => "50.0" },
          { "Country" => "GB", "State" => "London", "Net Sales (USD)" => "75.0" }
        ]

        expect(parsed_rows).to match_array(expected_rows)
      end

      it "enqueues emails to recipients" do
        travel_to Time.zone.local(2023, 8, 15) do
          job.perform
        end

        expect(AccountingMailer).to have_received(:ytd_sales_report).with(any_args, csv_report_emails[0]).once
        expect(AccountingMailer).to have_received(:ytd_sales_report).with(any_args, csv_report_emails[1]).once
        expect(mailer_double).to have_received(:deliver_now).twice
      end
    end
  end
end
