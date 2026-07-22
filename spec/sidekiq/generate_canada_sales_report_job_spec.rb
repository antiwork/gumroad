# frozen_string_literal: true

require "spec_helper"

describe GenerateCanadaSalesReportJob do
  let(:month) { 8 }
  let(:year) { 2022 }

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

    # Stub TaxJar since this test is about report generation, not tax calculation
    before do
      taxjar_response = {
        "amount_to_collect" => 0,
        "rate" => 0,
        "has_nexus" => false,
        "freight_taxable" => false,
        "tax_source" => nil,
        "breakdown" => {
          "state_tax_rate" => 0,
          "county_tax_rate" => 0,
          "city_tax_rate" => 0,
          "gst_tax_rate" => 0,
          "pst_tax_rate" => 0,
          "qst_tax_rate" => 0
        },
        "jurisdictions" => {
          "state" => nil,
          "county" => nil,
          "city" => nil
        }
      }
      allow_any_instance_of(TaxjarApi).to receive(:calculate_tax_for_order).and_return(taxjar_response)
    end

    before :context do
      @s3_object = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/canada-sales-reporting-spec-#{SecureRandom.hex(18)}.zip")
    end

    before do
      canada_product = nil
      spain_product = nil

      travel_to(Time.find_zone("UTC").local(2022, 7, 1)) do
        canada_creator = create(:user).tap do |creator|
          creator.fetch_or_build_user_compliance_info.dup_and_save! do |new_compliance_info|
            new_compliance_info.country = "Canada"
            new_compliance_info.state = "BC"
          end
        end
        canada_product = create(:product, user: canada_creator, price_cents: 100_00, native_type: "digital")

        spain_creator = create(:user).tap do |creator|
          creator.fetch_or_build_user_compliance_info.dup_and_save! do |new_compliance_info|
            new_compliance_info.country = "Spain"
          end
        end
        spain_product = create(:product, user: spain_creator, price_cents: 100_00, native_type: "digital")
      end

      travel_to(Time.find_zone("UTC").local(2022, 7, 30)) do
        create(:purchase_in_progress, link: canada_product, country: "Canada", state: "BC")

        Purchase.in_progress.find_each do |purchase|
          purchase.chargeable = create(:chargeable)
          purchase.process!
          purchase.update_balance_and_mark_successful!
        end
      end

      travel_to(Time.find_zone("UTC").local(2022, 8, 1)) do
        create(:purchase_in_progress, link: spain_product, country: "Spain")
        @purchase1 = create(:purchase_in_progress, link: canada_product, country: "Canada", state: "ON")
        @purchase2 = create(:purchase_in_progress, link: canada_product, country: "United States", zip_code: "22207")
        @purchase3 = create(:purchase_in_progress, link: canada_product, country: "Spain")

        Purchase.in_progress.find_each do |purchase|
          purchase.chargeable = create(:chargeable)
          purchase.process!
          purchase.update_balance_and_mark_successful!
        end
      end

      travel_to(Time.find_zone("UTC").local(2022, 9, 1)) do
        create(:purchase_in_progress, link: canada_product, country: "Canada", state: "QC")

        Purchase.in_progress.find_each do |purchase|
          purchase.chargeable = create(:chargeable)
          purchase.process!
          purchase.update_balance_and_mark_successful!
        end
      end
    end

    it "creates a CSV file for Canada sales" do
      expect(s3_bucket_double).to receive(:object).ordered.and_return(@s3_object)

      described_class.new.perform(month, year)

      expect(InternalNotificationWorker).to have_enqueued_sidekiq_job("payments", "Canada Sales Fees Reporting", anything, "green")

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      actual_payload = CSV.read(temp_file)

      expect(actual_payload.length).to eq(4)
      expect(actual_payload[0]).to eq([
                                        "Sale time",
                                        "Sale ID",
                                        "Seller ID",
                                        "Seller Name",
                                        "Seller Email",
                                        "Seller Country",
                                        "Seller Province",
                                        "Product ID",
                                        "Product Name",
                                        "Product / Subscription",
                                        "Product Type",
                                        "Physical/Digital Product",
                                        "Direct-To-Customer/Buy-Sell Product",
                                        "Buyer ID",
                                        "Buyer Name",
                                        "Buyer Email",
                                        "Buyer Card",
                                        "Buyer Country",
                                        "Buyer State",
                                        "Price",
                                        "Total Gumroad Fee",
                                        "Gumroad Discover Fee",
                                        "Creator Sales Tax",
                                        "Gumroad Sales Tax",
                                        "Shipping",
                                        "Total"
                                      ])
      expect(actual_payload[1]).to eq([
                                        "2022-08-01 00:00:00 UTC",
                                        @purchase1.external_id,
                                        @purchase1.seller.external_id,
                                        @purchase1.seller.name_or_username,
                                        @purchase1.seller.form_email&.gsub(/.{0,4}@/, '####@'),
                                        "Canada",
                                        "British Columbia",
                                        @purchase1.link.external_id,
                                        "The Works of Edgar Gumstein",
                                        "Product",
                                        "digital",
                                        "Digital",
                                        "BS",
                                        nil,
                                        nil,
                                        @purchase1.email&.gsub(/.{0,4}@/, '####@'),
                                        "**** **** **** 4242",
                                        "Canada",
                                        "ON",
                                        "10000",
                                        "1370",
                                        "0",
                                        "0",
                                        "0",
                                        "0",
                                        "10000"
                                      ])
      expect(actual_payload[2]).to eq([
                                        "2022-08-01 00:00:00 UTC",
                                        @purchase2.external_id,
                                        @purchase2.seller.external_id,
                                        @purchase2.seller.name_or_username,
                                        @purchase2.seller.form_email&.gsub(/.{0,4}@/, '####@'),
                                        "Canada",
                                        "British Columbia",
                                        @purchase2.link.external_id,
                                        "The Works of Edgar Gumstein",
                                        "Product",
                                        "digital",
                                        "Digital",
                                        "BS",
                                        nil,
                                        nil,
                                        @purchase2.email&.gsub(/.{0,4}@/, '####@'),
                                        "**** **** **** 4242",
                                        "United States",
                                        "Uncategorized",
                                        "10000",
                                        "1370",
                                        "0",
                                        "0",
                                        "0",
                                        "0",
                                        "10000"
                                      ])
      expect(actual_payload[3]).to eq([
                                        "2022-08-01 00:00:00 UTC",
                                        @purchase3.external_id,
                                        @purchase3.seller.external_id,
                                        @purchase3.seller.name_or_username,
                                        @purchase3.seller.form_email&.gsub(/.{0,4}@/, '####@'),
                                        "Canada",
                                        "British Columbia",
                                        @purchase3.link.external_id,
                                        "The Works of Edgar Gumstein",
                                        "Product",
                                        "digital",
                                        "Digital",
                                        "BS",
                                        nil,
                                        nil,
                                        @purchase3.email&.gsub(/.{0,4}@/, '####@'),
                                        "**** **** **** 4242",
                                        "Spain",
                                        "Uncategorized",
                                        "10000",
                                        "1370",
                                        "0",
                                        "0",
                                        "0",
                                        "0",
                                        "10000"
                                      ])
    end
  end

  describe "chargeback event-date attribution" do
    let(:s3_bucket_double) do
      s3_bucket_double = double
      allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket).and_return(s3_bucket_double)
      s3_bucket_double
    end

    before :context do
      @s3_object = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/canada-sales-fees-chargeback-spec-#{SecureRandom.hex(18)}.csv")
    end

    let(:cutover) { Purchase::Reportable::CHARGEBACK_REPORTING_CUTOVER.beginning_of_day }

    before do
      # Sold in the month before the cutover month; charged back post-cutover; dispute won
      # two months after the event. Each event must land in its own month's report.
      @seller_setup_time = (cutover - 1.month).beginning_of_month + 13.days
      @sale_time = (cutover - 1.month).beginning_of_month + 14.days
      @event_time = cutover + 5.days
      @won_time = cutover + 2.months

      canada_creator = nil
      product = nil
      travel_to(@seller_setup_time) do
        canada_creator = create(:user).tap do |creator|
          creator.fetch_or_build_user_compliance_info.dup_and_save! do |new_compliance_info|
            new_compliance_info.country = "Canada"
            new_compliance_info.state = "BC"
          end
        end
        product = create(:product, user: canada_creator, price_cents: 100_00, native_type: "digital")
      end

      travel_to(@sale_time) do
        @chargedback_purchase = create(:purchase, link: product, seller: canada_creator,
                                                  price_cents: 100_00, fee_cents: 13_70,
                                                  total_transaction_cents: 100_00,
                                                  country: "Canada", state: "ON")

        # A legacy chargeback (event before the cutover): keeps the historical drop.
        @legacy_chargedback_purchase = create(:purchase, link: product, seller: canada_creator,
                                                         price_cents: 100_00, fee_cents: 13_70,
                                                         total_transaction_cents: 100_00,
                                                         country: "Canada", state: "ON")
      end

      @legacy_chargedback_purchase.update!(chargeback_date: cutover - 10.days)
      @chargedback_purchase.update!(chargeback_date: @event_time)

      travel_to(@won_time) do
        @chargedback_purchase.update!(chargeback_reversed: true)
        create(:dispute, purchase: @chargedback_purchase, state: "won", won_at: Time.current)
      end
    end

    def perform_and_read(month, year)
      expect(s3_bucket_double).to receive(:object).and_return(@s3_object)

      described_class.new.perform(month, year)

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      CSV.read(temp_file)
    ensure
      temp_file&.close(true)
    end

    it "keeps the event-dated chargeback's sale in the purchase month and drops only the legacy one" do
      payload = perform_and_read(@sale_time.month, @sale_time.year)

      # Header + the event-dated purchase's sale row; the legacy chargeback stays dropped
      # (as filed), and the chargeback legs belong to later months.
      expect(payload.length).to eq(2)
      expect(payload[1][1]).to eq(@chargedback_purchase.external_id)
      expect(payload[1][19]).to eq("10000") # Price, gross
    end

    it "reports the chargeback as a negative row in the month the dispute was formalized" do
      payload = perform_and_read(@event_time.month, @event_time.year)

      expect(payload.length).to eq(2)
      row = payload[1]
      expect(row[0]).to eq(@event_time.to_s)
      expect(row[1]).to eq(@chargedback_purchase.external_id)
      expect(row[19]).to eq("-10000") # Price
      expect(row[20]).to eq("-1370")  # Total Gumroad Fee
      expect(row[25]).to eq("-10000") # Total
    end

    it "adds the won dispute back as a positive row in the month of won_at" do
      payload = perform_and_read(@won_time.month, @won_time.year)

      expect(payload.length).to eq(2)
      row = payload[1]
      expect(row[0]).to eq(@won_time.to_s)
      expect(row[1]).to eq(@chargedback_purchase.external_id)
      expect(row[19]).to eq("10000")
      expect(row[25]).to eq("10000")
    end

    it "omits a chargeback fully refunded before the dispute, since nothing is left to claw back" do
      fully_refunded = nil
      travel_to(@sale_time) do
        fully_refunded = create(:purchase, link: @chargedback_purchase.link, seller: @chargedback_purchase.seller,
                                           price_cents: 100_00, fee_cents: 13_70, total_transaction_cents: 100_00,
                                           country: "Canada", state: "ON")
        # Refund every amount (price, fee, tax, total) before the chargeback, so the dispute
        # has nothing left to claw back and every *_for_chargeback_reporting value is zero.
        create(:refund, purchase: fully_refunded,
                        amount_cents: fully_refunded.price_cents,
                        fee_cents: fully_refunded.fee_cents,
                        gumroad_tax_cents: fully_refunded.gumroad_tax_cents,
                        creator_tax_cents: fully_refunded.tax_cents,
                        total_transaction_cents: fully_refunded.total_transaction_cents)
      end
      fully_refunded.update!(chargeback_date: @event_time)

      payload = perform_and_read(@event_time.month, @event_time.year)

      ids = payload.drop(1).map { |row| row[1] }
      expect(ids).to include(@chargedback_purchase.external_id) # a real clawback is still reported
      expect(ids).not_to include(fully_refunded.external_id)    # zero clawback ⇒ no spurious all-zero row
    end
  end
end
