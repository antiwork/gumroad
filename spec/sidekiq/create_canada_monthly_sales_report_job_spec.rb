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

      expect(InternalNotificationWorker).to have_enqueued_sidekiq_job("payments", "Canada Sales Reporting", anything, "green")

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

  describe "refund period attribution" do
    let(:s3_bucket_double) do
      s3_bucket_double = double
      allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket).and_return(s3_bucket_double)
      s3_bucket_double
    end

    before :context do
      @s3_object = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/canada-monthly-refund-attribution-spec-#{SecureRandom.hex(18)}.csv")
    end

    let(:cutover) { Purchase::Reportable::REFUND_REPORTING_CUTOVER }
    let(:report_month_start) { (cutover + 1.month).beginning_of_month }

    before do
      product = create(:product, price_cents: 100_00, native_type: "digital")

      # Sold (post-cutover) in the month before the reported one, refunded during the reported
      # month: the refund must appear in the reported month as a negative row.
      travel_to(report_month_start - 5.days) do
        @cross_month_purchase = create(:purchase, link: product, price_cents: 100_00, fee_cents: 30_00,
                                                  gumroad_tax_cents: 13_00, total_transaction_cents: 113_00,
                                                  country: "Canada", state: "ON", ip_country: "Canada")
      end

      travel_to(report_month_start + 5.days) do
        @refund = create(:refund, purchase: @cross_month_purchase, amount_cents: 50_00, fee_cents: 15_00,
                                  gumroad_tax_cents: 6_50, total_transaction_cents: 56_50)
        @cross_month_purchase.update!(stripe_partially_refunded: true)
      end
    end

    it "reports the refund as a negative row in the month the refund happened" do
      expect(s3_bucket_double).to receive(:object).and_return(@s3_object)

      described_class.new.perform(report_month_start.month, report_month_start.year)

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      actual_payload = CSV.read(temp_file)

      # Header + the refund row. The purchase itself was sold the month before, so its sale
      # row belongs to that month, not this one.
      expect(actual_payload.length).to eq(2)
      refund_row = actual_payload[1]
      expect(refund_row[0]).to eq(@cross_month_purchase.external_id)
      expect(refund_row[1]).to eq(@refund.created_at.strftime("%m/%d/%Y"))
      expect(refund_row[9]).to eq("-6.50")   # Calculated Tax Amount
      expect(refund_row[10]).to eq("-6.50")  # Tax Collected by Gumroad
      expect(refund_row[11]).to eq("-50.00") # Price
      expect(refund_row[12]).to eq("-15.00") # Gumroad Fee
      expect(refund_row[14]).to eq("-56.50") # Total

      temp_file.close(true)
    end

    it "does not restate the purchase's own month when re-generated after the refund" do
      expect(s3_bucket_double).to receive(:object).and_return(@s3_object)

      purchase_month = report_month_start - 1.month
      described_class.new.perform(purchase_month.month, purchase_month.year)

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      actual_payload = CSV.read(temp_file)

      # The sale month regenerates with the purchase at its gross amounts — the later refund
      # belongs to the following month and must not leak backwards.
      expect(actual_payload.length).to eq(2)
      sale_row = actual_payload[1]
      expect(sale_row[0]).to eq(@cross_month_purchase.external_id)
      expect(sale_row[11]).to eq("100.00") # Price, gross

      temp_file.close(true)
    end
  end

  describe "chargeback event-date attribution" do
    let(:s3_bucket_double) do
      s3_bucket_double = double
      allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket).and_return(s3_bucket_double)
      s3_bucket_double
    end

    before :context do
      @s3_object = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/canada-monthly-chargeback-attribution-spec-#{SecureRandom.hex(18)}.csv")
    end

    let(:cutover) { Purchase::Reportable::CHARGEBACK_REPORTING_CUTOVER.beginning_of_day }

    before do
      product = create(:product, price_cents: 100_00, native_type: "digital")

      # Sold in the month before the cutover month; charged back post-cutover; dispute won
      # two months after the event. Each event must land in its own month's report.
      @sale_time = (cutover - 1.month).beginning_of_month + 14.days
      @event_time = cutover + 5.days
      @won_time = cutover + 2.months

      travel_to(@sale_time) do
        @chargedback_purchase = create(:purchase, link: product, price_cents: 100_00, fee_cents: 30_00,
                                                  gumroad_tax_cents: 13_00, total_transaction_cents: 113_00,
                                                  country: "Canada", state: "ON", ip_country: "Canada")

        # A legacy chargeback (event before the cutover): keeps the historical drop.
        @legacy_chargedback_purchase = create(:purchase, link: product, price_cents: 100_00, fee_cents: 30_00,
                                                         gumroad_tax_cents: 13_00, total_transaction_cents: 113_00,
                                                         country: "Canada", state: "ON", ip_country: "Canada")
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

      # Header + the event-dated purchase's sale row. The legacy chargeback stays dropped
      # (as filed); the chargeback legs belong to later months and must not leak backwards.
      expect(payload.length).to eq(2)
      expect(payload[1][0]).to eq(@chargedback_purchase.external_id)
      expect(payload[1][11]).to eq("100.00") # Price, gross
    end

    it "reports the chargeback as a negative row in the month the dispute was formalized" do
      payload = perform_and_read(@event_time.month, @event_time.year)

      expect(payload.length).to eq(2)
      row = payload[1]
      expect(row[0]).to eq(@chargedback_purchase.external_id)
      expect(row[1]).to eq(@event_time.strftime("%m/%d/%Y"))
      expect(row[9]).to eq("-13.00")   # Calculated Tax Amount
      expect(row[10]).to eq("-13.00")  # Tax Collected by Gumroad
      expect(row[11]).to eq("-100.00") # Price
      expect(row[12]).to eq("-13.70")  # Gumroad Fee (the factory recalculates fees on build)
      expect(row[14]).to eq("-113.00") # Total
    end

    it "adds the won dispute back as a positive row in the month of won_at" do
      payload = perform_and_read(@won_time.month, @won_time.year)

      expect(payload.length).to eq(2)
      row = payload[1]
      expect(row[0]).to eq(@chargedback_purchase.external_id)
      expect(row[1]).to eq(@won_time.strftime("%m/%d/%Y"))
      expect(row[11]).to eq("100.00")
      expect(row[14]).to eq("113.00")
    end

    it "omits a chargeback fully refunded before the dispute, since nothing is left to claw back" do
      fully_refunded = nil
      travel_to(@sale_time) do
        fully_refunded = create(:purchase, link: @chargedback_purchase.link,
                                           price_cents: 100_00, fee_cents: 30_00, gumroad_tax_cents: 13_00,
                                           total_transaction_cents: 113_00,
                                           country: "Canada", state: "ON", ip_country: "Canada")
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

      ids = payload.drop(1).map { |row| row[0] }
      expect(ids).to include(@chargedback_purchase.external_id) # a real clawback is still reported
      expect(ids).not_to include(fully_refunded.external_id)    # zero clawback ⇒ no spurious all-zero row
    end
  end
end
