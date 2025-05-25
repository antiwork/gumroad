# frozen_string_literal: true

require "spec_helper"

describe CreateCanadaMonthlySalesReportJob do
  let(:month) { 1 }
  let(:year) { 2015 }

  it "raises an argument error if the year is out of bounds" do
    expect { described_class.new.perform(month, 2013) }.to raise_error(ArgumentError)
  end

  it "raises an agrument error if the month is out of bounds" do
    expect { described_class.new.perform(13, year) }.to raise_error(ArgumentError)
  end

  describe "happy case", :vcr do
    let(:s3_bucket_double) do
      s3_bucket_double = double
      allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket).and_return(s3_bucket_double)
      s3_bucket_double
    end

    before :context do
      @s3_object = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/international-sales-reporting-spec-#{SecureRandom.hex(18)}.zip")
    end

    before do
      allow_any_instance_of(Link).to receive(:recommendable?).and_return(true)
      subscription_product = nil
      subscription = nil
      travel_to(Time.zone.local(2014, 12, 1)) do
        subscription_product = create(:subscription_product, price_cents: 100_00)
        subscription = create(:subscription, link_id: subscription_product.id)
        create(:purchase, link: subscription_product, is_original_subscription_purchase: true, subscription:, was_product_recommended: true, country: "Canada", state: nil)
      end
      travel_to(Time.zone.local(2015, 1, 1)) do
        product = create(:product, price_cents: 100_00, native_type: "digital")

        @purchase1 = create(:purchase_in_progress, link: product, was_product_recommended: true, country: "Canada", state: "ON", ip_country: "Canada")
        @purchase2 = create(:purchase_in_progress, link: product, was_product_recommended: true, country: "Canada", state: "QC", ip_country: "Canada")
        @purchase3 = create(:purchase_in_progress, link: product, country: "Canada", state: "AB", ip_country: "Canada")
        create(:purchase_in_progress, link: product, country: "Singapore")
        create(:purchase_in_progress, link: product, country: "Canada", state: "saskatoon")
        create(:purchase_in_progress, link: product, country: "Canada", state: "ON", card_country: "US", ip_country: "United States")
        create(:purchase_in_progress, link: subscription_product, subscription:, country: "Canada", state: nil)

        Purchase.in_progress.find_each do |purchase|
          purchase.chargeable = create(:chargeable)
          purchase.process!
          purchase.update_balance_and_mark_successful!
        end
      end
    end

    it "creates a CSV file for all sales into Canada" do
      expect(s3_bucket_double).to receive(:object).ordered.and_return(@s3_object)

      described_class.new.perform(month, year)

      expect(SlackMessageWorker).to have_enqueued_sidekiq_job("payments", "Canada Sales Reporting", anything, "green")

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      actual_payload = CSV.read(temp_file)

      expect(actual_payload.length).to eq(4)
      expect(actual_payload[0]).to eq([
                                        "Purchase External ID",
                                        "Purchase Date",
                                        "Member State of Consumption",
                                        "Gumroad Product Type",
                                        "TaxJar Product Tax Code",
                                        "GST Tax Rate",
                                        "PST Tax Rate",
                                        "QST Tax Rate",
                                        "Combined Tax Rate",
                                        "Calculated Tax Amount",
                                        "Tax Collected by Gumroad",
                                        "Price",
                                        "Gumroad Fee",
                                        "Shipping",
                                        "Total",
                                        "Receipt URL",
                                      ])

      expect(@purchase1.purchase_taxjar_info).to be_present
      expect(actual_payload[1]).to eq([
                                        @purchase1.external_id,
                                        "01/01/2015",
                                        "Ontario",
                                        "digital",
                                        "31000",
                                        "0.05",
                                        "0.08",
                                        "0.0",
                                        "0.13",
                                        "13.00",
                                        "13.00",
                                        "100.00",
                                        "30.00",
                                        "0.00",
                                        "113.00",
                                        @purchase1.receipt_url,
                                      ])

      expect(@purchase2.purchase_taxjar_info).to be_present
      expect(actual_payload[2]).to eq([
                                        @purchase2.external_id,
                                        "01/01/2015",
                                        "Quebec",
                                        "digital",
                                        "31000",
                                        "0.05",
                                        "0.0",
                                        "0.09975",
                                        "0.14975",
                                        "14.98",
                                        "14.98",
                                        "100.00",
                                        "30.00",
                                        "0.00",
                                        "114.98",
                                        @purchase2.receipt_url,
                                      ])
    end
  end
end
