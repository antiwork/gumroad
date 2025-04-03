# frozen_string_literal: true

require "spec_helper"

describe CreateUsStateMonthlySalesReportsJob do
  let (:subdivision_code) { "WA" }
  let(:month) { 8 }
  let (:year) { 2022 }

  it "raises an argument error if the year is out of bounds" do
    expect { described_class.new.perform(subdivision_code, month, 2013) }.to raise_error(ArgumentError)
  end

  it "raises an argument error if the month is out of bounds" do
    expect { described_class.new.perform(subdivision_code, 13, year) }.to raise_error(ArgumentError)
  end

  it "raises an argument error if the subdivision code is not valid" do
    expect { described_class.new.perform("subdivision", month, year) }.to raise_error(ArgumentError)
  end

  describe "happy case", :vcr do
    let(:s3_bucket_double) do
      s3_bucket_double = double
      allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket).and_return(s3_bucket_double)
      s3_bucket_double
    end

    before :context do
      @s3_object = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/washington-reporting-spec-#{SecureRandom.hex(18)}.zip")
    end

    before do
      travel_to(Time.find_zone("UTC").local(2022, 8, 10)) do
        product = create(:product, price_cents: 100_00, native_type: "digital")

        @purchase1 = create(:purchase_in_progress, link: product, was_product_recommended: true, country: "United States", zip_code: "98121") # King County, Washington
        @purchase2 = create(:purchase_in_progress, link: product, was_product_recommended: true, country: "United States", zip_code: "94016") # San Francisco, California
        @purchase3 = create(:purchase_in_progress, link: product, country: "United States", zip_code: "98184") # Seattle, Washington (TaxJar returns King County, instead of Seattle though)
        @purchase4 = create(:purchase_in_progress, link: product, country: "United States", zip_code: "98612", gumroad_tax_cents: 760) # Wahkiakum County, Washington
        @purchase5 = create(:purchase_in_progress, link: product, country: "United States", zip_code: "19464", gumroad_tax_cents: 760, ip_address: "67.183.58.7") # Montgomery County, Pennsylvania with IP address in Washington
        @purchase6 = create(:purchase_in_progress, link: product, was_product_recommended: true, country: "United States", zip_code: "98121", quantity: 3) # King County, Washington

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

    it "creates CSV files for sales into the state of Washington" do
      expect(s3_bucket_double).to receive(:object).ordered.and_return(@s3_object)
      expect_any_instance_of(TaxjarApi).to receive(:create_order_transaction).exactly(6).times.and_call_original

      described_class.new.perform(subdivision_code, month, year)

      expect(SlackMessageWorker).to have_enqueued_sidekiq_job("payments", "US Sales Tax Reporting", anything, "green")

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      actual_payload = CSV.read(temp_file)

      expect(actual_payload.length).to eq(7)
      expect(actual_payload[0]).to eq([
                                        "Purchase External ID",
                                        "Purchase Date",
                                        "Member State of Consumption",
                                        "Total Transaction",
                                        "Price",
                                        "Tax Collected by Gumroad",
                                        "Combined Tax Rate",
                                        "Calculated Tax Amount",
                                        "Jurisdiction State",
                                        "Jurisdiction County",
                                        "Jurisdiction City",
                                        "State Tax Rate",
                                        "County Tax Rate",
                                        "City Tax Rate",
                                        "Amount not collected by Gumroad",
                                        "Gumroad Product Type",
                                        "TaxJar Product Tax Code",
                                      ])

      expect(@purchase1.purchase_taxjar_info).to be_present
      expect(actual_payload[1]).to eq([
                                        @purchase1.external_id,
                                        "08/10/2022",
                                        "Washington",
                                        "110.35",
                                        "100.00",
                                        "10.35",
                                        "0.1035",
                                        "10.35",
                                        "WA",
                                        "KING",
                                        "SEATTLE",
                                        "0.065",
                                        "0.004",
                                        "0.0115",
                                        "0.00",
                                        "digital",
                                        "31000"
                                      ])

      expect(actual_payload[2]).to eq([
                                        @purchase3.external_id,
                                        "08/10/2022",
                                        "Washington",
                                        "110.20",
                                        "100.00",
                                        "10.20",
                                        "0.102",
                                        "10.20",
                                        "WA",
                                        "KING",
                                        nil,
                                        "0.065",
                                        "0.004",
                                        "0.01",
                                        "0.00",
                                        "digital",
                                        "31000"
                                      ])

      expect(actual_payload[3]).to eq([
                                        @purchase4.external_id,
                                        "08/10/2022",
                                        "Washington",
                                        "107.80",
                                        "100.00",
                                        "7.80",
                                        "0.078",
                                        "7.80",
                                        "WA",
                                        "WAHKIAKUM",
                                        nil,
                                        "0.065",
                                        "0.003",
                                        "0.01",
                                        "0.00",
                                        "digital",
                                        "31000"
                                      ])

      expect(actual_payload[4]).to eq([
                                        @purchase6.external_id,
                                        "08/10/2022",
                                        "Washington",
                                        "331.05",
                                        "300.00",
                                        "31.05",
                                        "0.1035",
                                        "31.05",
                                        "WA",
                                        "KING",
                                        "SEATTLE",
                                        "0.065",
                                        "0.004",
                                        "0.0115",
                                        "0.00",
                                        "digital",
                                        "31000"
                                      ])

      expect(actual_payload[5]).to eq([
                                        @purchase_to_refund.external_id,
                                        "08/10/2022",
                                        "Washington",
                                        "77.80",
                                        "72.17",
                                        "5.63",
                                        "0.078",
                                        "5.63",
                                        "WA",
                                        "CLARK",
                                        nil,
                                        "0.065",
                                        "0.003",
                                        "0.01",
                                        "0.00",
                                        "digital",
                                        "31000"
                                      ])

      # When TaxJar info is not stored for a purchase, it fetches the latest
      # info from TaxJar API to calculate the tax amount
      expect(@purchase_without_taxjar_info.purchase_taxjar_info).to be_nil
      expect(actual_payload[6]).to eq([
                                        @purchase_without_taxjar_info.external_id,
                                        "08/10/2022",
                                        "Washington",
                                        "106.50",
                                        "100.00",
                                        "6.50",
                                        "0.078",
                                        "7.80",
                                        "WA",
                                        "WAHKIAKUM",
                                        nil,
                                        "0.065",
                                        "0.003",
                                        "0.01",
                                        "1.30",
                                        "digital",
                                        "31000"
                                      ])
    end
  end
end
