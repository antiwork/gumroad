# frozen_string_literal: true

require "spec_helper"

describe CreateIndiaSalesReportJob do
  describe "#perform" do
    it "raises an ArgumentError if the year is less than 2014 or greater than 3200" do
      expect do
        described_class.new.perform(1, 2013)
      end.to raise_error(ArgumentError)

      expect do
        described_class.new.perform(1, 3201)
      end.to raise_error(ArgumentError)
    end

    it "raises an ArgumentError if the month is not within 1 and 12 inclusive" do
      expect do
        described_class.new.perform(0, 2023)
      end.to raise_error(ArgumentError)

      expect do
        described_class.new.perform(13, 2023)
      end.to raise_error(ArgumentError)
    end

    it "defaults to previous month when no parameters provided" do
      travel_to(Time.zone.local(2023, 6, 15)) do
        # Mock S3 to prevent real API calls
        s3_bucket_double = double
        s3_object_double = double
        allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket).and_return(s3_bucket_double)
        allow(s3_bucket_double).to receive(:object).and_return(s3_object_double)
        allow(s3_object_double).to receive(:upload_file)
        allow(s3_object_double).to receive(:presigned_url).and_return("https://example.com/test-url")

        # Mock Slack notification
        allow(SlackMessageWorker).to receive(:perform_async)

        # Mock database queries to prevent actual data access
        purchase_double = double
        allow(Purchase).to receive(:joins).and_return(purchase_double)
        allow(purchase_double).to receive(:where).and_return(purchase_double)
        allow(purchase_double).to receive_message_chain(:where, :not).and_return(purchase_double)
        allow(purchase_double).to receive(:find_each).and_return([])

        # Mock ZipTaxRate lookup
        zip_tax_rate_double = double
        allow(ZipTaxRate).to receive_message_chain(:where, :alive, :last).and_return(zip_tax_rate_double)
        allow(zip_tax_rate_double).to receive(:combined_rate).and_return(0.18)

        # Test that it defaults to previous month (May 2023)
        described_class.new.perform

        # Verify it processed the correct month by checking the S3 filename pattern
        expect(s3_bucket_double).to have_received(:object).with(/india-sales-report-2023-05-/)
      end
    end

    let(:s3_bucket_double) do
      s3_bucket_double = double
      allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket).and_return(s3_bucket_double)
      s3_bucket_double
    end

    before :context do
      @s3_object = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/india-sales-report-spec-#{SecureRandom.hex(18)}.csv")
    end

    before do
      Feature.activate(:collect_tax_in)

      create(:zip_tax_rate, country: "IN", state: nil, zip_code: nil, combined_rate: 0.18, is_seller_responsible: false)

      test_time = Time.zone.local(2023, 6, 15)
      product = create(:product, price_cents: 1000)

      travel_to(test_time) do
        @india_purchase = create(:purchase,
                                 link: product,
                                 purchaser: product.user,
                                 purchase_state: "in_progress",
                                 quantity: 1,
                                 perceived_price_cents: 1000,
                                 country: "India",
                                 ip_country: "India",
                                 ip_state: "MH",
                                 stripe_transaction_id: "txn_test123"
        )
        @india_purchase.mark_test_successful!
        @india_purchase.update!(gumroad_tax_cents: 180)

        vat_purchase = create(:purchase,
                              link: product,
                              purchaser: product.user,
                              purchase_state: "in_progress",
                              quantity: 1,
                              perceived_price_cents: 1000,
                              country: "India",
                              ip_country: "India",
                              stripe_transaction_id: "txn_test456"
        )
        vat_purchase.mark_test_successful!
        vat_purchase.create_purchase_sales_tax_info!(business_vat_id: "GST123456789")

        refunded_purchase = create(:purchase,
                                   link: product,
                                   purchaser: product.user,
                                   purchase_state: "in_progress",
                                   quantity: 1,
                                   perceived_price_cents: 1000,
                                   country: "India",
                                   ip_country: "India",
                                   stripe_transaction_id: "txn_test789"
        )
        refunded_purchase.mark_test_successful!
        refunded_purchase.stripe_refunded = true
        refunded_purchase.save!
      end
    end

    it "generates CSV report for India sales" do
      expect(s3_bucket_double).to receive(:object).and_return(@s3_object)

      described_class.new.perform(6, 2023)

      expect(SlackMessageWorker).to have_enqueued_sidekiq_job("payments", "India Sales Reporting", anything, "green")

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      actual_payload = CSV.read(temp_file)

      expect(actual_payload[0]).to eq([
                                        "ID",
                                        "Date",
                                        "Place of Supply (State)",
                                        "Zip Tax Rate (%) (Rate from Database)",
                                        "Taxable Value (cents)",
                                        "Integrated Tax Amount (cents)",
                                        "Tax Rate (%) (Calculated From Tax Collected)",
                                        "Expected Tax (cents, rounded)",
                                        "Expected Tax (cents, floored)",
                                        "Tax Difference (rounded)",
                                        "Tax Difference (floored)"
                                      ])

      expect(actual_payload.length).to eq(2)

      data_row = actual_payload[1]

      expect(data_row[0]).to eq(@india_purchase.external_id)  # ID
      expect(data_row[1]).to eq("2023-06-15")                 # Date
      expect(data_row[2]).to eq("MH")                         # Place of Supply (State)
      expect(data_row[3]).to eq("18")                         # Zip Tax Rate (%) (Rate from Database)
      expect(data_row[4]).to eq("1000")                       # Taxable Value (cents)
      expect(data_row[5]).to eq("180")                        # Integrated Tax Amount (cents) - gumroad_tax_cents is 180
      expect(data_row[6]).to eq("18.0")                       # Tax Rate (%) (Calculated From Tax Collected) - (180/1000 * 100) = 18.0
      expect(data_row[7]).to eq("180")                        # Expected Tax (cents, rounded) - (1000 * 0.18).round = 180
      expect(data_row[8]).to eq("180")                        # Expected Tax (cents, floored) - (1000 * 0.18).floor = 180
      expect(data_row[9]).to eq("0")                          # Tax Difference (rounded) - 180 - 180 = 0
      expect(data_row[10]).to eq("0")                         # Tax Difference (floored) - 180 - 180 = 0

      temp_file.close(true)
    end

    it "excludes purchases with business VAT ID" do
      expect(s3_bucket_double).to receive(:object).and_return(@s3_object)

      described_class.new.perform(6, 2023)

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      actual_payload = CSV.read(temp_file)

      expect(actual_payload.length).to eq(2)
      temp_file.close(true)
    end

    it "handles invalid Indian states" do
      # Create test data without time travel to avoid S3 time skew
      invalid_product = create(:product, price_cents: 500)
      invalid_state_purchase = create(:purchase,
                                      link: invalid_product,
                                      purchaser: invalid_product.user,
                                      purchase_state: "in_progress",
                                      quantity: 1,
                                      perceived_price_cents: 500,
                                      country: "India",
                                      ip_country: "India",
                                      ip_state: "123",
                                      stripe_transaction_id: "txn_invalid_state",
                                      created_at: Time.zone.local(2023, 6, 15)
      )
      invalid_state_purchase.mark_test_successful!

      # Use a separate S3 object to avoid time skew issues
      s3_object_invalid = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/india-sales-report-invalid-#{SecureRandom.hex(18)}.csv")
      expect(s3_bucket_double).to receive(:object).and_return(s3_object_invalid)

      described_class.new.perform(6, 2023)

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      s3_object_invalid.get(response_target: temp_file)
      temp_file.rewind
      actual_payload = CSV.read(temp_file)

      invalid_state_row = actual_payload.find { |row| row[0] == invalid_state_purchase.external_id }
      expect(invalid_state_row).to be_present

      # Check all column values for invalid state purchase
      expect(invalid_state_row[0]).to eq(invalid_state_purchase.external_id)  # ID
      expect(invalid_state_row[1]).to eq("2023-06-15")                        # Date
      expect(invalid_state_row[2]).to eq("")                                  # Place of Supply (State) - empty for invalid state
      expect(invalid_state_row[3]).to eq("18")                                # Zip Tax Rate (%) (Rate from Database)
      expect(invalid_state_row[4]).to eq("500")                               # Taxable Value (cents)
      expect(invalid_state_row[5]).to eq("0")                                 # Integrated Tax Amount (cents) - gumroad_tax_cents is 0 for test purchase
      expect(invalid_state_row[6]).to eq("0")                                 # Tax Rate (%) (Calculated From Tax Collected) - 0 since no tax collected
      expect(invalid_state_row[7]).to eq("90")                                # Expected Tax (cents, rounded) - (500 * 0.18).round = 90
      expect(invalid_state_row[8]).to eq("90")                                # Expected Tax (cents, floored) - (500 * 0.18).floor = 90
      expect(invalid_state_row[9]).to eq("90")                                # Tax Difference (rounded) - 90 - 0 = 90
      expect(invalid_state_row[10]).to eq("90")                               # Tax Difference (floored) - 90 - 0 = 90

      temp_file.close(true)
    end
  end
end
