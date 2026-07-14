# frozen_string_literal: true

require "spec_helper"

describe CreateVatReportJob do
  it "raises an ArgumentError if the year is less than 2014 or greater than 3200" do
    expect do
      described_class.new.perform(2, 2013)
    end.to raise_error(ArgumentError)
  end

  it "raises an ArgumentError if the quarter is not within 1 and 4 inclsusive" do
    expect do
      described_class.new.perform(0, 2013)
    end.to raise_error(ArgumentError)

    expect do
      described_class.new.perform(5, 2013)
    end.to raise_error(ArgumentError)
  end

  describe "happy case", :vcr do
    let(:s3_bucket_double) do
      s3_bucket_double = double
      allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket).and_return(s3_bucket_double)
      s3_bucket_double
    end

    before :context do
      @s3_object = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/vat-reporting-spec-#{SecureRandom.hex(18)}.zip")
    end

    before do
      create(:zip_tax_rate, country: "AT", state: nil, zip_code: nil, combined_rate: 0.20, flags: 0)
      create(:zip_tax_rate, country: "AT", state: nil, zip_code: nil, combined_rate: 0.10, flags: 2)
      create(:zip_tax_rate, country: "ES", state: nil, zip_code: nil, combined_rate: 0.21, flags: 0)
      create(:zip_tax_rate, country: "GB", state: nil, zip_code: nil, combined_rate: 0.20, flags: 0)
      create(:zip_tax_rate, country: "CY", state: nil, zip_code: nil, combined_rate: 0.19, flags: 0)

      q1_time = Time.zone.local(2015, 1, 1)
      q1_m2_time = Time.zone.local(2015, 2, 1)
      q2_time = Time.zone.local(2015, 5, 1)

      product = create(:product, price_cents: 200_00)
      epublication_product = create(:product, price_cents: 300_00, is_epublication: true)

      travel_to(q1_time) do
        at_test_purchase1 = create(:purchase, link: product, purchaser: product.user, purchase_state: "in_progress",
                                              quantity: 2, perceived_price_cents: 200_00, country: "Austria", ip_country: "Austria")
        at_test_purchase1.mark_test_successful!

        at_test_purchase2 = create(:purchase, link: epublication_product, purchaser: epublication_product.user, purchase_state: "in_progress",
                                              quantity: 2, perceived_price_cents: 300_00, country: "Austria", ip_country: "Austria")
        at_test_purchase2.mark_test_successful!

        es_test_purchase1 = create(:purchase, link: product, purchaser: product.user, purchase_state: "in_progress",
                                              quantity: 2, perceived_price_cents: 400_00, country: "Spain", ip_country: "Spain")
        es_test_purchase1.mark_test_successful!

        gb_purchase1 = create(:purchase, link: product, chargeable: build(:chargeable), quantity: 1,
                                         perceived_price_cents: 200_00, country: "United Kingdom", ip_country: "United Kingdom")
        gb_purchase1.process!

        gb_purchase2 = create(:purchase, link: product, chargeable: build(:chargeable), quantity: 1,
                                         perceived_price_cents: 200_00, country: "United Kingdom", ip_country: "United Kingdom")
        gb_purchase2.process!
        gb_purchase2.refund_gumroad_taxes!(refunding_user_id: 1)

        cy_purchase_1 = create(:purchase, link: product, chargeable: build(:chargeable), quantity: 1,
                                          perceived_price_cents: 200_00, country: "Cyprus", ip_country: "Cyprus")
        cy_purchase_1.process!

        cy_purchase_1_refund_flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, cy_purchase_1.gross_amount_refundable_cents)
        cy_purchase_1.refund_purchase!(cy_purchase_1_refund_flow_of_funds, nil)

        gb_purchase1.chargeback_date = Time.current
        gb_purchase1.chargeback_reversed = true
        gb_purchase1.save!
      end

      travel_to(q1_m2_time) do
        at_test_purchase1 = create(:purchase, link: product, purchaser: product.user, purchase_state: "in_progress",
                                              quantity: 2, perceived_price_cents: 200_00, country: "Austria", ip_country: "Austria")
        at_test_purchase1.mark_test_successful!

        at_test_purchase2 = create(:purchase, link: epublication_product, purchaser: epublication_product.user, purchase_state: "in_progress",
                                              quantity: 2, perceived_price_cents: 300_00, country: "Austria", ip_country: "Austria")
        at_test_purchase2.mark_test_successful!

        es_test_purchase1 = create(:purchase, link: product, purchaser: product.user, purchase_state: "in_progress",
                                              quantity: 2, perceived_price_cents: 400_00, country: "Spain", ip_country: "Spain")
        es_test_purchase1.mark_test_successful!

        gb_purchase1 = create(:purchase, link: product, chargeable: build(:chargeable), quantity: 1,
                                         perceived_price_cents: 200_00, country: "United Kingdom", ip_country: "United Kingdom")
        gb_purchase1.process!

        create(:purchase, link: product, chargeable: build(:chargeable), quantity: 1,
                          perceived_price_cents: 200_00, country: "United Kingdom", ip_country: "United Kingdom").process!

        cy_purchase_1 = create(:purchase, link: product, chargeable: build(:chargeable), quantity: 1,
                                          perceived_price_cents: 200_00, country: "Cyprus", ip_country: "Cyprus")
        cy_purchase_1.process!

        cy_purchase_1_refund_flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, cy_purchase_1.gross_amount_refundable_cents)
        cy_purchase_1.refund_purchase!(cy_purchase_1_refund_flow_of_funds, nil)

        gb_purchase1.chargeback_date = Time.current
        gb_purchase1.chargeback_reversed = true
        gb_purchase1.save!
      end

      travel_to(q2_time) do
        es_purchase2 = build(:purchase, link: product, chargeable: build(:chargeable),
                                        quantity: 2, perceived_price_cents: 400_00, country: "Spain", ip_country: "Spain")
        es_purchase2.process!

        gb_purchase2 = build(:purchase, link: product, chargeable: build(:chargeable), quantity: 1,
                                        perceived_price_cents: 200_00, country: "United Kingdom", ip_country: "United Kingdom")
        gb_purchase2.process!

        es_purchase2.chargeback_date = Time.current
        es_purchase2.chargeback_reversed = true
        es_purchase2.save!
      end
    end

    it "returns a zipped file containing a csv file for every month in the quarter" do
      expect(s3_bucket_double).to receive(:object).and_return(@s3_object)
      expect(AccountingMailer).to receive(:vat_report).with(1, 2015, anything).and_call_original
      allow_any_instance_of(described_class).to receive(:gbp_to_usd_rate_for_date).and_return(1.5)

      described_class.new.perform(1, 2015)

      expect(InternalNotificationWorker).to have_enqueued_sidekiq_job("payments", "VAT Reporting", anything, "green")

      report_verification_helper
    end

    def report_verification_helper
      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")

      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      actual_payload = CSV.read(temp_file)

      expect(actual_payload[0]).to eq(["Member State of Consumption", "VAT rate type", "VAT rate in Member State",
                                       "Total value of supplies excluding VAT (USD)",
                                       "Total value of supplies excluding VAT (Estimated, USD)",
                                       "VAT amount due (USD)",
                                       "Total value of supplies excluding VAT (GBP)",
                                       "Total value of supplies excluding VAT (Estimated, GBP)",
                                       "VAT amount due (GBP)"])
      expect(actual_payload[1]).to eq(["Austria", "Standard", "20.0", "0.00", "0.00", "0.00", "0.00", "0.00", "0.00"])
      expect(actual_payload[2]).to eq(["Austria", "Reduced", "10.0", "0.00", "0.00", "0.00", "0.00", "0.00", "0.00"])
      expect(actual_payload[3]).to eq(["Spain", "Standard", "21.0", "0.00", "0.00", "0.00", "0.00", "0.00", "0.00"])
      expect(actual_payload[4]).to eq(["United Kingdom", "Standard", "20.0", "800.00", "600.00", "120.00", "533.33", "400.00", "80.00"])
      expect(actual_payload[5]).to eq(["Cyprus", "Standard", "19.0", "0.00", "0.00", "0.00", "0.00", "0.00", "0.00"])
    ensure
      temp_file.close(true)
    end
  end

  describe "refund period attribution" do
    let(:s3_bucket_double) do
      s3_bucket_double = double
      allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket).and_return(s3_bucket_double)
      s3_bucket_double
    end

    before :context do
      @s3_object = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/vat-reporting-refund-attribution-spec-#{SecureRandom.hex(18)}.csv")
    end

    before do
      zip_tax_rate = create(:zip_tax_rate, country: "AT", state: nil, zip_code: nil, combined_rate: 0.20, flags: 0)

      travel_to(Time.zone.local(2023, 11, 15)) do
        # Sold in Q4 2023, refunded in Q1 2024. The refund must reduce the Q1 2024
        # report (the period the refund happened in), and re-generating the Q4 2023
        # report must NOT be changed by the later refund.
        @cross_quarter_purchase = create(:purchase, zip_tax_rate:, price_cents: 100_00, gumroad_tax_cents: 20_00,
                                                    country: "Austria", ip_country: "Austria")
      end

      travel_to(Time.zone.local(2024, 1, 10)) do
        create(:refund, purchase: @cross_quarter_purchase, amount_cents: 50_00, gumroad_tax_cents: 10_00)

        # An ordinary same-quarter sale, so the Q1 2024 totals are non-zero and the
        # refund subtraction is visible against them.
        create(:purchase, zip_tax_rate:, price_cents: 100_00, gumroad_tax_cents: 20_00,
                          country: "Austria", ip_country: "Austria")

        # A purchase that was charged back outright never contributes VAT to the report,
        # so a refund against it must not be subtracted either — otherwise the same VAT
        # would be relieved twice (once by the chargeback exclusion, once by the refund).
        chargedback_purchase = create(:purchase, zip_tax_rate:, price_cents: 100_00, gumroad_tax_cents: 20_00,
                                                 country: "Austria", ip_country: "Austria")
        chargedback_purchase.update!(chargeback_date: Time.current)
        create(:refund, purchase: chargedback_purchase, amount_cents: 100_00, gumroad_tax_cents: 20_00)

        # A purchase with no settled charge is never counted on the sales side, so its
        # refund must not be subtracted from VAT we never reported. Paid purchases can't
        # be built without transaction info, so null the column directly.
        unsettled_purchase = create(:purchase, zip_tax_rate:, price_cents: 100_00, gumroad_tax_cents: 20_00,
                                               country: "Austria", ip_country: "Austria")
        unsettled_purchase.update_column(:stripe_transaction_id, nil)
        create(:refund, purchase: unsettled_purchase, amount_cents: 100_00, gumroad_tax_cents: 20_00)
      end
    end

    it "subtracts a refund in the quarter the refund happened, not the purchase's quarter" do
      expect(s3_bucket_double).to receive(:object).and_return(@s3_object)
      allow_any_instance_of(described_class).to receive(:gbp_to_usd_rate_for_date).and_return(2.0)

      described_class.new.perform(1, 2024)

      actual_payload = read_report_csv

      # Q1 2024 sales: one 100.00 purchase with 20.00 VAT (the charged-back and
      # unsettled purchases are excluded). Subtractions: only the cross-quarter
      # refund of 50.00 with 10.00 VAT. Supplies 100.00 - 50.00 = 50.00, VAT due
      # 20.00 - 10.00 = 10.00, estimated supplies 10.00 / 0.20 = 50.00. GBP columns
      # are the USD amounts at the stubbed rate of 2.0.
      expect(actual_payload[1]).to eq(["Austria", "Standard", "20.0", "50.00", "50.00", "10.00", "25.00", "25.00", "5.00"])
    end

    it "does not change a past quarter's report when a refund happens after that quarter closed" do
      expect(s3_bucket_double).to receive(:object).and_return(@s3_object)
      allow_any_instance_of(described_class).to receive(:gbp_to_usd_rate_for_date).and_return(2.0)

      described_class.new.perform(4, 2023)

      actual_payload = read_report_csv

      # Q4 2023 contains only the original 100.00 sale with 20.00 VAT. The refund
      # issued in January 2024 belongs to Q1 2024 and must not leak backwards into a
      # re-generated Q4 2023 report (whose return may already be filed).
      expect(actual_payload[1]).to eq(["Austria", "Standard", "20.0", "100.00", "100.00", "20.00", "50.00", "50.00", "10.00"])
    end

    def read_report_csv
      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      CSV.read(temp_file)
    ensure
      temp_file.close(true)
    end
  end
end
