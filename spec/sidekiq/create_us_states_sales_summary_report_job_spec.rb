# frozen_string_literal: true

require "spec_helper"

describe CreateUsStatesSalesSummaryReportJob do
  let(:subdivision_codes) { ["WA", "WI"] }
  let(:month) { 8 }
  let(:year) { 2022 }

  it "is configured with retry: 3" do
    expect(described_class.sidekiq_options["retry"]).to eq(3)
  end

  describe "sidekiq_retries_exhausted" do
    it "emails payments notification with the failure context" do
      job = { "args" => [["WA", "WI"], 4, 2026] }
      exception = ActiveRecord::StatementTimeout.new("maximum statement execution time exceeded")
      mailer = double("mailer")

      expect(AccountingMailer).to receive(:us_states_sales_summary_report_failed)
        .with(["WA", "WI"], 4, 2026, "ActiveRecord::StatementTimeout", "maximum statement execution time exceeded")
        .and_return(mailer)
      expect(mailer).to receive(:deliver_later)

      described_class.sidekiq_retries_exhausted_block.call(job, exception)
    end
  end

  it "raises an argument error if the year is out of bounds" do
    expect { described_class.new.perform(subdivision_codes, month, 2013) }.to raise_error(ArgumentError)
  end

  it "raises an argument error if the month is out of bounds" do
    expect { described_class.new.perform(subdivision_codes, 13, year) }.to raise_error(ArgumentError)
  end

  it "raises an argument error if any subdivision code is not valid" do
    expect { described_class.new.perform(["WA", "subdivision"], month, year) }.to raise_error(ArgumentError)
  end

  describe "happy case", :vcr do
    let(:s3_bucket_double) do
      s3_bucket_double = double
      allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket).and_return(s3_bucket_double)
      s3_bucket_double
    end

    before :context do
      @s3_object = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/us-states-sales-summary-spec-#{SecureRandom.hex(18)}.csv")
    end

    before do
      travel_to(Time.find_zone("UTC").local(2022, 8, 10)) do
        product = create(:product, price_cents: 100_00, native_type: "digital")

        @purchase1 = create(:purchase_in_progress, link: product, was_product_recommended: true, country: "United States", zip_code: "98121") # King County, Washington
        @purchase2 = create(:purchase_in_progress, link: product, was_product_recommended: true, country: "United States", zip_code: "53703") # Madison, Wisconsin
        @purchase3 = create(:purchase_in_progress, link: product, country: "United States", zip_code: "98184") # Seattle, Washington
        @purchase4 = create(:purchase_in_progress, link: product, country: "United States", zip_code: "98612", gumroad_tax_cents: 760) # Wahkiakum County, Washington
        @purchase5 = create(:purchase_in_progress, link: product, country: "United States", zip_code: "19464", gumroad_tax_cents: 760, ip_address: "67.183.58.7") # Montgomery County, Pennsylvania with IP address in Washington
        @purchase6 = create(:purchase_in_progress, link: product, was_product_recommended: true, country: "United States", zip_code: "98121", quantity: 3) # King County, Washington
        @purchase7 = create(:purchase_in_progress, link: product, country: "United States", zip_code: "53202", gumroad_tax_cents: 850) # Milwaukee, Wisconsin

        @purchase_to_refund = create(:purchase_in_progress, link: product, country: "United States", zip_code: "98604", gumroad_tax_cents: 780) # Hockinson County, Washington
        refund_flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 30_00)
        @purchase_to_refund.refund_purchase!(refund_flow_of_funds, nil)

        @purchase_without_taxjar_info = create(:purchase, link: product, country: "United States", zip_code: "98612", gumroad_tax_cents: 650) # Wahkiakum County, Washington

        Purchase.in_progress.find_each do |purchase|
          purchase.chargeable = create(:chargeable)
          purchase.process!
          purchase.update_balance_and_mark_successful!
        end
      end
    end

    it "creates a summary CSV file with correct totals for each state and submits transactions to TaxJar" do
      expect(s3_bucket_double).to receive(:object).ordered.and_return(@s3_object)
      expect_any_instance_of(TaxjarApi).to receive(:create_order_transaction).exactly(8).times.and_call_original

      described_class.new.perform(subdivision_codes, month, year, true)

      expect(InternalNotificationWorker).to have_enqueued_sidekiq_job("payments", "US Sales Tax Summary Report", anything, "green")

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      actual_payload = CSV.read(temp_file)

      expect(actual_payload).to eq([
                                     ["State", "GMV", "Number of orders", "Sales tax collected"],
                                     ["Washington", "843.70", "6", "71.53"],
                                     ["Wisconsin", "212.59", "2", "12.59"]
                                   ])

      expect(@purchase1.purchase_taxjar_info).to be_present
      expect(@purchase2.purchase_taxjar_info).to be_present
      expect(@purchase3.purchase_taxjar_info).to be_present
      expect(@purchase4.purchase_taxjar_info).to be_present
      expect(@purchase5.purchase_taxjar_info).to be_present
      expect(@purchase6.purchase_taxjar_info).to be_present
      expect(@purchase_to_refund.purchase_taxjar_info).to be_present
      expect(@purchase_without_taxjar_info.purchase_taxjar_info).to be_nil

      expect(@purchase2.purchase_taxjar_info).to be_present
      expect(@purchase7.purchase_taxjar_info).to be_present
    end

    it "retries and completes the report when TaxJar raises a transient connection error" do
      expect(s3_bucket_double).to receive(:object).ordered.and_return(@s3_object)

      raised = false
      allow_any_instance_of(TaxjarApi).to receive(:create_order_transaction).and_wrap_original do |original, **kwargs|
        unless raised
          raised = true
          raise HTTP::ConnectionError, "failed to connect: Connection reset by peer - SSL_connect"
        end
        original.call(**kwargs)
      end
      allow_any_instance_of(UsStateSalesTaxUploader).to receive(:sleep)

      expect { described_class.new.perform(subdivision_codes, month, year, true) }.not_to raise_error

      expect(InternalNotificationWorker).to have_enqueued_sidekiq_job("payments", "US Sales Tax Summary Report", anything, "green")
    end

    it "creates a summary CSV file with correct totals for each state without submitting transactions to TaxJar when push_to_taxjar is false" do
      expect(s3_bucket_double).to receive(:object).ordered.and_return(@s3_object)
      expect_any_instance_of(TaxjarApi).not_to receive(:create_order_transaction)

      described_class.new.perform(subdivision_codes, month, year)

      expect(InternalNotificationWorker).to have_enqueued_sidekiq_job("payments", "US Sales Tax Summary Report", anything, "green")

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      actual_payload = CSV.read(temp_file)

      expect(actual_payload).to eq([
                                     ["State", "GMV", "Number of orders", "Sales tax collected"],
                                     ["Washington", "843.70", "6", "71.53"],
                                     ["Wisconsin", "212.59", "2", "12.59"]
                                   ])
    end
  end

  describe "refund period attribution" do
    let(:s3_bucket_double) do
      s3_bucket_double = double
      allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket).and_return(s3_bucket_double)
      s3_bucket_double
    end

    before :context do
      @s3_object = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/us-states-summary-refund-attribution-spec-#{SecureRandom.hex(18)}.csv")
    end

    let(:cutover) { UsStateSalesTaxUploader::REFUND_REPORTING_CUTOVER }
    let(:report_month_start) { (cutover + 1.month).beginning_of_month }

    before do
      product = create(:product, price_cents: 100_00, native_type: "digital")

      # Sold (post-cutover) in the month before the reported one, refunded during the reported
      # month: the refund must be subtracted from the reported month's totals.
      travel_to(report_month_start - 5.days) do
        @cross_month_purchase = create(:purchase, link: product, price_cents: 100_00, total_transaction_cents: 110_10,
                                                  gumroad_tax_cents: 10_10, country: "United States", zip_code: "98121") # Washington
      end

      travel_to(report_month_start + 5.days) do
        @refund = create(:refund, purchase: @cross_month_purchase, amount_cents: 50_00,
                                  gumroad_tax_cents: 5_05, total_transaction_cents: 55_05)
        @cross_month_purchase.update!(stripe_partially_refunded: true)
      end

      # A same-month sale so the reported month has a positive base to subtract from.
      travel_to(report_month_start + 3.days) do
        create(:purchase, link: product, price_cents: 100_00, total_transaction_cents: 110_10,
                          gumroad_tax_cents: 10_10, country: "United States", zip_code: "98184") # Washington
      end
    end

    it "subtracts the refund from the month the refund happened without counting it as an order" do
      expect(s3_bucket_double).to receive(:object).and_return(@s3_object)

      described_class.new.perform(["WA"], report_month_start.month, report_month_start.year)

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      actual_payload = CSV.read(temp_file)
      temp_file.close(true)

      # One order this month (110.10 GMV, 10.10 tax) minus the cross-month refund
      # (55.05, 5.05). Order count stays 1 — the refunded order belongs to last month.
      expect(actual_payload).to eq([
                                     ["State", "GMV", "Number of orders", "Sales tax collected"],
                                     ["Washington", "55.05", "1", "5.05"]
                                   ])
    end

    it "does not restate the purchase's own month when re-generated after the refund" do
      expect(s3_bucket_double).to receive(:object).and_return(@s3_object)

      purchase_month = report_month_start - 1.month
      described_class.new.perform(["WA"], purchase_month.month, purchase_month.year)

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      actual_payload = CSV.read(temp_file)
      temp_file.close(true)

      # The sale month regenerates at gross — the later refund belongs to the following month.
      expect(actual_payload).to eq([
                                     ["State", "GMV", "Number of orders", "Sales tax collected"],
                                     ["Washington", "110.10", "1", "10.10"]
                                   ])
    end
  end

  describe "pre-cutover purchase fully refunded after the cutover" do
    let(:s3_bucket_double) do
      s3_bucket_double = double
      allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket).and_return(s3_bucket_double)
      s3_bucket_double
    end

    before :context do
      @s3_object = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/us-states-summary-precutover-refund-spec-#{SecureRandom.hex(18)}.csv")
    end

    let(:cutover) { UsStateSalesTaxUploader::REFUND_REPORTING_CUTOVER }
    let(:refund_month_start) { (cutover + 1.month).beginning_of_month }

    before do
      product = create(:product, price_cents: 100_00, native_type: "digital")

      # Sold before the cutover, fully refunded after it. The sale month must keep the order
      # at gross (its refund is reported in the refund's own month), and the refund month must
      # subtract the refund — never both dropping the sale AND subtracting the refund.
      travel_to(cutover.beginning_of_day - 5.days) do
        @pre_cutover_purchase = create(:purchase, link: product, price_cents: 100_00, total_transaction_cents: 110_10,
                                                  gumroad_tax_cents: 10_10, country: "United States", zip_code: "98121") # Washington
      end

      travel_to(refund_month_start + 5.days) do
        create(:refund, purchase: @pre_cutover_purchase, amount_cents: 100_00,
                        gumroad_tax_cents: 10_10, total_transaction_cents: 110_10)
        @pre_cutover_purchase.update!(stripe_refunded: true)
      end

      # A same-month sale so the refund month has a positive base to subtract from.
      travel_to(refund_month_start + 3.days) do
        create(:purchase, link: product, price_cents: 100_00, total_transaction_cents: 110_10,
                          gumroad_tax_cents: 10_10, country: "United States", zip_code: "98184") # Washington
      end
    end

    it "keeps the fully refunded order at gross in its sale month" do
      expect(s3_bucket_double).to receive(:object).and_return(@s3_object)

      sale_month = cutover - 5.days
      described_class.new.perform(["WA"], sale_month.month, sale_month.year)

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      actual_payload = CSV.read(temp_file)
      temp_file.close(true)

      # No pre-cutover refunds to net, so the sale month reports the order at gross even
      # though it is now fully refunded — the refund lands in the refund's own month.
      expect(actual_payload).to eq([
                                     ["State", "GMV", "Number of orders", "Sales tax collected"],
                                     ["Washington", "110.10", "1", "10.10"]
                                   ])
    end

    it "subtracts the refund from the refund's month" do
      expect(s3_bucket_double).to receive(:object).and_return(@s3_object)

      described_class.new.perform(["WA"], refund_month_start.month, refund_month_start.year)

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      actual_payload = CSV.read(temp_file)
      temp_file.close(true)

      # One order this month (110.10 GMV, 10.10 tax) minus the pre-cutover purchase's refund
      # (110.10, 10.10). Order count stays 1 — the refunded order belongs to its sale month.
      expect(actual_payload).to eq([
                                     ["State", "GMV", "Number of orders", "Sales tax collected"],
                                     ["Washington", "0.00", "1", "0.00"]
                                   ])
    end
  end

  describe "chargeback period attribution" do
    let(:s3_bucket_double) do
      s3_bucket_double = double
      allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket).and_return(s3_bucket_double)
      s3_bucket_double
    end

    before :context do
      @s3_object = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/us-states-summary-chargeback-attribution-spec-#{SecureRandom.hex(18)}.csv")
    end

    let(:cutover) { Purchase::Reportable::CHARGEBACK_REPORTING_CUTOVER }
    let(:event_month_start) { (cutover + 1.month).beginning_of_month }
    let(:won_month_start) { (cutover + 3.months).beginning_of_month }

    before do
      product = create(:product, price_cents: 100_00, native_type: "digital")

      # Sold before the event month; dispute formalized in the event month; a second
      # purchase's dispute won in a later month.
      travel_to(cutover.beginning_of_day - 20.days) do
        @chargedback_purchase = create(:purchase, link: product, price_cents: 100_00, total_transaction_cents: 110_10,
                                                  gumroad_tax_cents: 10_10, country: "United States", zip_code: "98121") # Washington
        @won_purchase = create(:purchase, link: product, price_cents: 100_00, total_transaction_cents: 110_10,
                                          gumroad_tax_cents: 10_10, country: "United States", zip_code: "98121")
        # A legacy chargeback: dispute formalized before the cutover — no legs anywhere.
        @legacy_purchase = create(:purchase, link: product, price_cents: 100_00, total_transaction_cents: 110_10,
                                             gumroad_tax_cents: 10_10, country: "United States", zip_code: "98121")
      end

      @legacy_purchase.update!(chargeback_date: cutover.beginning_of_day - 10.days)
      @chargedback_purchase.update!(chargeback_date: event_month_start + 5.days)
      @won_purchase.update!(chargeback_date: event_month_start + 6.days)

      travel_to(won_month_start + 2.days) do
        @won_purchase.update!(chargeback_reversed: true)
        create(:dispute, purchase: @won_purchase, state: "won", won_at: Time.current)
      end

      # A same-month sale so the event month has a positive base to subtract from.
      travel_to(event_month_start + 3.days) do
        create(:purchase, link: product, price_cents: 100_00, total_transaction_cents: 110_10,
                          gumroad_tax_cents: 10_10, country: "United States", zip_code: "98184") # Washington
      end
    end

    def read_report(month, year)
      expect(s3_bucket_double).to receive(:object).and_return(@s3_object)
      described_class.new.perform(["WA"], month, year)

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      CSV.read(temp_file)
    ensure
      temp_file&.close(true)
    end

    it "keeps event-dated chargebacks' orders in the sale month and drops only the legacy one" do
      sale_month = cutover - 20.days
      actual_payload = read_report(sale_month.month, sale_month.year)

      # The two event-dated chargebacks keep their orders at gross (their clawbacks land in
      # later months); only the legacy chargeback stays excluded, as filed.
      expect(actual_payload).to eq([
                                     ["State", "GMV", "Number of orders", "Sales tax collected"],
                                     ["Washington", "220.20", "2", "20.20"]
                                   ])
    end

    it "subtracts chargebacks in the month the dispute was formalized without touching the order count" do
      actual_payload = read_report(event_month_start.month, event_month_start.year)

      # One order this month (110.10, 10.10) minus the two disputes formalized this month
      # (110.10 + 10.10 each). Order count stays 1 — the charged-back orders belong to their
      # own sale month.
      expect(actual_payload).to eq([
                                     ["State", "GMV", "Number of orders", "Sales tax collected"],
                                     ["Washington", "-110.10", "1", "-10.10"]
                                   ])
    end

    it "adds a won dispute back in the month of won_at" do
      actual_payload = read_report(won_month_start.month, won_month_start.year)

      expect(actual_payload).to eq([
                                     ["State", "GMV", "Number of orders", "Sales tax collected"],
                                     ["Washington", "110.10", "0", "10.10"]
                                   ])
    end
  end
end
