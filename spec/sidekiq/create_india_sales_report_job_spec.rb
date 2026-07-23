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

        # Mock notification
        allow(InternalNotificationWorker).to receive(:perform_async)

        # Mock database queries to prevent actual data access
        purchase_double = double
        allow(Purchase).to receive(:joins).and_return(purchase_double)
        allow(purchase_double).to receive(:where).and_return(purchase_double)
        allow(purchase_double).to receive_message_chain(:where, :not).and_return(purchase_double)
        allow(purchase_double).to receive(:find_each).and_return([])

        refund_double = double
        allow(Refund).to receive(:effective).and_return(refund_double)
        allow(refund_double).to receive(:joins).and_return(refund_double)
        allow(refund_double).to receive(:where).and_return(refund_double)
        allow(refund_double).to receive_message_chain(:where, :not).and_return(refund_double)
        allow(refund_double).to receive(:find_each).and_return([])

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

        # A purchase refunded inside the same month. The sale must still appear as a
        # "sale" entry (dated by the purchase), and the refund as its own "refund"
        # entry (dated by the refund) — refunded purchases are no longer dropped.
        @refunded_purchase = create(:purchase,
                                    link: product,
                                    purchaser: product.user,
                                    purchase_state: "in_progress",
                                    quantity: 1,
                                    perceived_price_cents: 1000,
                                    country: "India",
                                    ip_country: "India",
                                    ip_state: "MH",
                                    stripe_transaction_id: "txn_test789"
        )
        @refunded_purchase.mark_test_successful!
        @refunded_purchase.update!(gumroad_tax_cents: 180)
        @refunded_purchase.stripe_refunded = true
        @refunded_purchase.save!
        create(:refund, purchase: @refunded_purchase, amount_cents: 1000, gumroad_tax_cents: 180)
      end
    end

    it "generates CSV report for India sales" do
      expect(s3_bucket_double).to receive(:object).and_return(@s3_object)

      described_class.new.perform(6, 2023)

      expect(InternalNotificationWorker).to have_enqueued_sidekiq_job("payments", "India Sales Reporting", anything, "green")

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
                                        "Tax Difference (floored)",
                                        "Entry Type"
                                      ])

      # Header + two sale rows + one refund row (the VAT-registered purchase is excluded).
      expect(actual_payload.length).to eq(4)

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
      expect(data_row[11]).to eq("sale")                      # Entry Type

      # The refunded purchase's gross sale stays in the report as a normal sale row...
      sale_row = actual_payload[2]
      expect(sale_row[0]).to eq(@refunded_purchase.external_id)
      expect(sale_row[4]).to eq("1000")
      expect(sale_row[5]).to eq("180")
      expect(sale_row[11]).to eq("sale")

      # ...and the refund appears as its own entry with negated amounts, dated by the refund.
      refund_row = actual_payload[3]
      expect(refund_row[0]).to eq(@refunded_purchase.external_id)
      expect(refund_row[1]).to eq("2023-06-15")
      expect(refund_row[2]).to eq("MH")
      expect(refund_row[4]).to eq("-1000")
      expect(refund_row[5]).to eq("-180")
      expect(refund_row[6]).to eq("18.0")
      expect(refund_row[7]).to eq("-180")
      expect(refund_row[8]).to eq("-180")
      expect(refund_row[9]).to eq("0")
      expect(refund_row[10]).to eq("0")
      expect(refund_row[11]).to eq("refund")

      temp_file.close(true)
    end

    it "excludes purchases with business VAT ID" do
      expect(s3_bucket_double).to receive(:object).and_return(@s3_object)

      described_class.new.perform(6, 2023)

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      actual_payload = CSV.read(temp_file)

      # Header + two sale rows + one refund row; the VAT-registered purchase contributes nothing.
      expect(actual_payload.length).to eq(4)
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

    describe "cross-month refund attribution" do
      before do
        cross_month_product = create(:product, price_cents: 2000)

        # Sold in June 2023, refunded in July 2023. The sale must stay in June's
        # report (dated by the purchase), and the refund must appear only in July's
        # report (dated by the refund) — so re-generating June after the refund is
        # issued no longer silently shrinks an already-filed month.
        travel_to(Time.zone.local(2023, 6, 20)) do
          @cross_month_purchase = create(:purchase,
                                         link: cross_month_product,
                                         purchaser: cross_month_product.user,
                                         purchase_state: "in_progress",
                                         quantity: 1,
                                         perceived_price_cents: 2000,
                                         country: "India",
                                         ip_country: "India",
                                         ip_state: "KA",
                                         stripe_transaction_id: "txn_cross_month"
          )
          @cross_month_purchase.mark_test_successful!
          @cross_month_purchase.update!(gumroad_tax_cents: 360)
        end

        travel_to(Time.zone.local(2023, 7, 5)) do
          @cross_month_purchase.stripe_refunded = true
          @cross_month_purchase.save!
          create(:refund, purchase: @cross_month_purchase, amount_cents: 2000, gumroad_tax_cents: 360)
        end
      end

      it "keeps the sale in the purchase month's report even after it is refunded in a later month" do
        s3_object_june = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/india-sales-report-june-#{SecureRandom.hex(18)}.csv")
        expect(s3_bucket_double).to receive(:object).and_return(s3_object_june)

        described_class.new.perform(6, 2023)

        temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
        s3_object_june.get(response_target: temp_file)
        temp_file.rewind
        actual_payload = CSV.read(temp_file)

        sale_row = actual_payload.find { |row| row[0] == @cross_month_purchase.external_id }
        expect(sale_row).to be_present
        expect(sale_row[1]).to eq("2023-06-20")
        expect(sale_row[4]).to eq("2000")
        expect(sale_row[5]).to eq("360")
        expect(sale_row[11]).to eq("sale")

        # The July refund must not leak backwards into June's report.
        refund_rows = actual_payload.select { |row| row[11] == "refund" && row[0] == @cross_month_purchase.external_id }
        expect(refund_rows).to be_empty

        temp_file.close(true)
      end

      it "reports the refund as its own entry in the month the refund happened" do
        s3_object_july = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/india-sales-report-july-#{SecureRandom.hex(18)}.csv")
        expect(s3_bucket_double).to receive(:object).and_return(s3_object_july)

        described_class.new.perform(7, 2023)

        temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
        s3_object_july.get(response_target: temp_file)
        temp_file.rewind
        actual_payload = CSV.read(temp_file)

        # July has no sales — only the refund entry for June's purchase.
        expect(actual_payload.length).to eq(2)

        refund_row = actual_payload[1]
        expect(refund_row[0]).to eq(@cross_month_purchase.external_id)
        expect(refund_row[1]).to eq("2023-07-05")
        expect(refund_row[2]).to eq("KA")
        expect(refund_row[4]).to eq("-2000")
        expect(refund_row[5]).to eq("-360")
        expect(refund_row[11]).to eq("refund")

        temp_file.close(true)
      end
    end

    describe "terminally-failed refunds" do
      before do
        failed_refund_product = create(:product, price_cents: 5000)

        travel_to(Time.zone.local(2023, 9, 10)) do
          # A refund that failed after acceptance but whose balance debits were NOT reversed:
          # the seller is still out the money, so it must still back out of the report.
          @still_debited_purchase = create(:purchase,
                                           link: failed_refund_product,
                                           purchaser: failed_refund_product.user,
                                           purchase_state: "in_progress",
                                           quantity: 1,
                                           perceived_price_cents: 5000,
                                           country: "India",
                                           ip_country: "India",
                                           ip_state: "KA",
                                           stripe_transaction_id: "txn_still_debited"
          )
          @still_debited_purchase.mark_test_successful!
          @still_debited_purchase.update!(gumroad_tax_cents: 900)
          create(:refund, purchase: @still_debited_purchase, amount_cents: 5000, gumroad_tax_cents: 900, status: "failed")

          # A refund that failed AND had its balance debits reversed: the money came back to
          # us and the buyer never received it, so it must NOT back out of the report.
          @reversed_purchase = create(:purchase,
                                      link: failed_refund_product,
                                      purchaser: failed_refund_product.user,
                                      purchase_state: "in_progress",
                                      quantity: 1,
                                      perceived_price_cents: 5000,
                                      country: "India",
                                      ip_country: "India",
                                      ip_state: "KA",
                                      stripe_transaction_id: "txn_reversed"
          )
          @reversed_purchase.mark_test_successful!
          @reversed_purchase.update!(gumroad_tax_cents: 900)
          reversed_refund = create(:refund, purchase: @reversed_purchase, amount_cents: 5000, gumroad_tax_cents: 900, status: "failed")
          reversed_refund.balance_reversed_on_failure = true
          reversed_refund.balance_reversed_on_failure_at = Time.current.utc.iso8601
          reversed_refund.save!
        end
      end

      it "backs out a failed refund still on our books but ignores one whose balance debits were reversed" do
        s3_object_sept = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/india-sales-report-sept-#{SecureRandom.hex(18)}.csv")
        expect(s3_bucket_double).to receive(:object).and_return(s3_object_sept)

        described_class.new.perform(9, 2023)

        temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
        s3_object_sept.get(response_target: temp_file)
        temp_file.rewind
        actual_payload = CSV.read(temp_file)

        # Both sales are real (neither buyer was actually refunded) and stay as sale rows.
        expect(actual_payload.count { |row| row[11] == "sale" }).to eq(2)

        # Only the still-debited failed refund backs out; the reversed one is excluded by
        # Refund.effective. A blanket status filter would drop BOTH; the old unfiltered leg
        # would keep BOTH — so this pins the effective semantics specifically.
        refund_rows = actual_payload.select { |row| row[11] == "refund" }
        expect(refund_rows.map { |row| row[0] }).to contain_exactly(@still_debited_purchase.external_id)

        temp_file.close(true)
      end
    end

    describe "chargeback event-date attribution" do
      let(:cutover) { Purchase::Reportable::CHARGEBACK_REPORTING_CUTOVER.beginning_of_day }

      before do
        chargeback_product = create(:product, price_cents: 3000)

        # Sold in the month before the cutover month; charged back in the cutover month
        # (post-cutover event); dispute won two months later. Each event must land in its
        # own month's report.
        @sale_month = (cutover - 1.month).beginning_of_month + 14.days
        @event_time = cutover + 5.days
        @won_time = cutover + 2.months

        travel_to(@sale_month) do
          @chargedback_purchase = create(:purchase,
                                         link: chargeback_product,
                                         purchaser: chargeback_product.user,
                                         purchase_state: "in_progress",
                                         quantity: 1,
                                         perceived_price_cents: 3000,
                                         country: "India",
                                         ip_country: "India",
                                         ip_state: "MH",
                                         stripe_transaction_id: "txn_chargeback"
          )
          @chargedback_purchase.mark_test_successful!
          @chargedback_purchase.update!(gumroad_tax_cents: 540)

          # A legacy chargeback (event before the cutover): keeps the historical drop.
          @legacy_chargedback_purchase = create(:purchase,
                                                link: chargeback_product,
                                                purchaser: chargeback_product.user,
                                                purchase_state: "in_progress",
                                                quantity: 1,
                                                perceived_price_cents: 3000,
                                                country: "India",
                                                ip_country: "India",
                                                ip_state: "MH",
                                                stripe_transaction_id: "txn_legacy_chargeback"
          )
          @legacy_chargedback_purchase.mark_test_successful!
          @legacy_chargedback_purchase.update!(gumroad_tax_cents: 540)
        end

        @legacy_chargedback_purchase.update!(chargeback_date: cutover - 10.days)
        @chargedback_purchase.update!(chargeback_date: @event_time)

        travel_to(@won_time) do
          @chargedback_purchase.update!(chargeback_reversed: true)
          # One Dispute row carries both the formalization date (event_created_at, mirroring
          # chargeback_date) and the win date (won_at); the tax-period scopes resolve each
          # leg's window through it.
          create(:dispute, purchase: @chargedback_purchase, state: "won", event_created_at: @event_time, won_at: Time.current)
        end
      end

      def generate_report(month, year)
        s3_object = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/india-sales-report-cb-#{SecureRandom.hex(18)}.csv")
        expect(s3_bucket_double).to receive(:object).and_return(s3_object)

        described_class.new.perform(month, year)

        temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
        s3_object.get(response_target: temp_file)
        temp_file.rewind
        CSV.read(temp_file)
      ensure
        temp_file&.close(true)
      end

      it "keeps the event-dated chargeback's sale in the purchase month and drops only the legacy one" do
        payload = generate_report(@sale_month.month, @sale_month.year)

        sale_rows = payload.select { |row| row[11] == "sale" }
        expect(sale_rows.map(&:first)).to include(@chargedback_purchase.external_id)
        expect(sale_rows.map(&:first)).not_to include(@legacy_chargedback_purchase.external_id)

        # No chargeback entries leak into the sale month — the event belongs to a later month.
        expect(payload.count { |row| row[11] == "chargeback" }).to eq(0)
      end

      it "reports the chargeback as a negative entry in the month the dispute was formalized" do
        payload = generate_report(@event_time.month, @event_time.year)

        chargeback_rows = payload.select { |row| row[11] == "chargeback" }
        expect(chargeback_rows.length).to eq(1)

        row = chargeback_rows.first
        expect(row[0]).to eq(@chargedback_purchase.external_id)
        expect(row[1]).to eq(@event_time.strftime("%Y-%m-%d"))
        expect(row[2]).to eq("MH")
        expect(row[4]).to eq("-3000")
        expect(row[5]).to eq("-540")

        # The legacy chargeback emits no entry anywhere (kept as filed).
        expect(payload.map(&:first)).not_to include(@legacy_chargedback_purchase.external_id)
      end

      it "reports the won dispute as a positive entry in the month of won_at" do
        payload = generate_report(@won_time.month, @won_time.year)

        reversal_rows = payload.select { |row| row[11] == "chargeback_reversal" }
        expect(reversal_rows.length).to eq(1)

        row = reversal_rows.first
        expect(row[0]).to eq(@chargedback_purchase.external_id)
        expect(row[1]).to eq(@won_time.strftime("%Y-%m-%d"))
        expect(row[4]).to eq("3000")
        expect(row[5]).to eq("540")
      end
    end
  end
end
