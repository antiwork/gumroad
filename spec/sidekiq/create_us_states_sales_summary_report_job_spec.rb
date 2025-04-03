# frozen_string_literal: true

require "spec_helper"

describe CreateUsStatesSalesSummaryReportJob do
  let(:subdivision_codes) { ["WA", "WI"] }
  let(:month) { 8 }
  let(:year) { 2022 }

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

      described_class.new.perform(subdivision_codes, month, year)

      expect(SlackMessageWorker).to have_enqueued_sidekiq_job("payments", "US Sales Tax Summary Report", anything, "green")

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

    it "creates a summary CSV file with correct totals for each state without submitting transactions to TaxJar when push_to_taxjar is false" do
      expect(s3_bucket_double).to receive(:object).ordered.and_return(@s3_object)
      expect_any_instance_of(TaxjarApi).not_to receive(:create_order_transaction)

      described_class.new.perform(subdivision_codes, month, year, push_to_taxjar: false)

      expect(SlackMessageWorker).to have_enqueued_sidekiq_job("payments", "US Sales Tax Summary Report", anything, "green")

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
end
