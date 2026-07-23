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
  describe "failed refund semantics" do
    let(:s3_bucket_double) do
      s3_bucket_double = double
      allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket).and_return(s3_bucket_double)
      s3_bucket_double
    end

    before :context do
      @s3_object = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/vat-reporting-failed-refunds-spec-#{SecureRandom.hex(18)}.csv")
    end

    before do
      zip_tax_rate = create(:zip_tax_rate, country: "AT", state: nil, zip_code: nil, combined_rate: 0.20, flags: 0)

      travel_to(Time.zone.local(2024, 1, 15)) do
        # A refund can fail after Stripe accepted it (async bank-transfer refunds can
        # be returned by the buyer's bank). Until its balance debits are reversed, the
        # seller is still out the money, so the report must keep subtracting it.
        debited_purchase = create(:purchase, zip_tax_rate:, price_cents: 100_00, gumroad_tax_cents: 20_00,
                                             country: "Austria", ip_country: "Austria")
        create(:refund, purchase: debited_purchase, amount_cents: 100_00, gumroad_tax_cents: 20_00, status: "failed")

        # This refund also failed, but its balance debits were reversed — no money
        # actually left, so the report must not subtract it from VAT totals.
        reversed_purchase = create(:purchase, zip_tax_rate:, price_cents: 100_00, gumroad_tax_cents: 20_00,
                                              country: "Austria", ip_country: "Austria")
        reversed_refund = create(:refund, purchase: reversed_purchase, amount_cents: 100_00, gumroad_tax_cents: 20_00, status: "failed")
        reversed_refund.balance_reversed_on_failure = true
        reversed_refund.balance_reversed_on_failure_at = Time.current.utc.iso8601
        reversed_refund.save!
      end
    end

    it "subtracts a failed refund that was not reversed and ignores one whose balance debits were reversed" do
      expect(s3_bucket_double).to receive(:object).and_return(@s3_object)
      allow_any_instance_of(described_class).to receive(:gbp_to_usd_rate_for_date).and_return(2.0)

      described_class.new.perform(1, 2024)

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      actual_payload = CSV.read(temp_file)

      # Two purchases of 100.00 + 20.00 VAT each. Only the still-debited failed refund
      # (100.00 + 20.00 VAT) is subtracted: supplies 200.00 - 100.00 = 100.00, VAT due
      # 40.00 - 20.00 = 20.00. GBP columns are the USD amounts at the stubbed rate of 2.0.
      # If the reversed refund were also subtracted, every column would read 0.00.
      expect(actual_payload[1]).to eq(["Austria", "Standard", "20.0", "100.00", "100.00", "20.00", "50.00", "50.00", "10.00"])
    ensure
      temp_file.close(true)
    end
  end

  describe "chargeback period attribution" do
    let(:s3_bucket_double) do
      s3_bucket_double = double
      allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket).and_return(s3_bucket_double)
      s3_bucket_double
    end

    before :context do
      @s3_object = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/vat-reporting-chargeback-attribution-spec-#{SecureRandom.hex(18)}.csv")
    end

    let(:cutover) { Purchase::Reportable::CHARGEBACK_REPORTING_CUTOVER.beginning_of_day }

    before do
      zip_tax_rate = create(:zip_tax_rate, country: "AT", state: nil, zip_code: nil, combined_rate: 0.20, flags: 0)

      # All purchases are made in the quarter before the cutover's quarter, so the sale
      # period and the chargeback event period are distinct quarters.
      @purchase_quarter_time = cutover.beginning_of_quarter - 1.month # Q2 2026
      @event_quarter_time = cutover + 3.months                       # Q4 2026
      @won_quarter_time = cutover + 6.months                         # Q1 2027

      travel_to(@purchase_quarter_time) do
        # Charged back after the cutover, never won: the sale stays in its own quarter and
        # the clawback lands in the event's quarter.
        @event_dated_purchase = create(:purchase, zip_tax_rate:, price_cents: 100_00, gumroad_tax_cents: 20_00,
                                                  country: "Austria", ip_country: "Austria")

        # Charged back after the cutover and later won (dispute row records won_at): a debit
        # leg in the event quarter, a re-add leg in the won quarter.
        @won_purchase = create(:purchase, zip_tax_rate:, price_cents: 100_00, gumroad_tax_cents: 20_00,
                                          country: "Austria", ip_country: "Austria")

        # Charged back BEFORE the cutover: keeps the legacy treatment (dropped from the
        # purchase quarter on regeneration; no event-period legs).
        @legacy_purchase = create(:purchase, zip_tax_rate:, price_cents: 100_00, gumroad_tax_cents: 20_00,
                                             country: "Austria", ip_country: "Austria")

        # Marked reversed but with NO dispute row recording won_at: without a real reversal
        # date the legs can't balance, so it keeps the legacy treatment (a won chargeback's
        # sale stays in the purchase quarter; no legs anywhere).
        @undated_reversal_purchase = create(:purchase, zip_tax_rate:, price_cents: 100_00, gumroad_tax_cents: 20_00,
                                                       country: "Austria", ip_country: "Austria")

        # An ordinary, untouched sale so the purchase quarter's totals are non-zero.
        create(:purchase, zip_tax_rate:, price_cents: 100_00, gumroad_tax_cents: 20_00,
                          country: "Austria", ip_country: "Austria")

        # Partially refunded before its chargeback: the debit leg claws back only what the
        # refund didn't already return.
        @partially_refunded_purchase = create(:purchase, zip_tax_rate:, price_cents: 100_00, gumroad_tax_cents: 20_00,
                                                         country: "Austria", ip_country: "Austria")
        create(:refund, purchase: @partially_refunded_purchase, amount_cents: 40_00, gumroad_tax_cents: 8_00)
        @partially_refunded_purchase.update!(stripe_partially_refunded: true)
      end

      @legacy_purchase.update!(chargeback_date: cutover - 10.days)
      create(:dispute, purchase: @legacy_purchase, event_created_at: cutover - 10.days)

      travel_to(@event_quarter_time) do
        @event_dated_purchase.update!(chargeback_date: Time.current)
        @won_purchase.update!(chargeback_date: Time.current)
        @undated_reversal_purchase.update!(chargeback_date: Time.current, chargeback_reversed: true)
        @partially_refunded_purchase.update!(chargeback_date: Time.current)
        # chargeback_date mirrors the dispute's event_created_at, so give each formalized
        # chargeback its Dispute row — the tax-period scopes resolve the event quarter through
        # them. @won_purchase's row is created in the won quarter below carrying both dates.
        create(:dispute, purchase: @event_dated_purchase, event_created_at: Time.current)
        create(:dispute, purchase: @undated_reversal_purchase, event_created_at: Time.current)
        create(:dispute, purchase: @partially_refunded_purchase, event_created_at: Time.current)
      end

      travel_to(@won_quarter_time) do
        @won_purchase.update!(chargeback_reversed: true)
        create(:dispute, purchase: @won_purchase, state: "won", event_created_at: @event_quarter_time, won_at: Time.current)
      end
    end

    def perform_and_read(quarter, year)
      expect(s3_bucket_double).to receive(:object).and_return(@s3_object)
      allow_any_instance_of(described_class).to receive(:gbp_to_usd_rate_for_date).and_return(2.0)

      described_class.new.perform(quarter, year)

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      CSV.read(temp_file)
    ensure
      temp_file&.close(true)
    end

    it "keeps event-dated chargebacks' sales in the purchase quarter and drops only the legacy chargeback" do
      payload = perform_and_read(2, 2026)

      # Six purchases of 100.00/20.00 VAT were made in Q2 2026. The legacy (pre-cutover)
      # chargeback is dropped as filed; the undated reversal keeps its legacy won treatment
      # (sale stays); the event-dated, won, and partially refunded chargebacks all keep
      # their sale rows (their clawbacks belong to later quarters). The refund leg subtracts
      # the 40.00/8.00 refund in this, its own, quarter. Supplies: 5 * 100.00 - 40.00 =
      # 460.00; VAT: 5 * 20.00 - 8.00 = 92.00.
      expect(payload[1]).to eq(["Austria", "Standard", "20.0", "460.00", "460.00", "92.00", "230.00", "230.00", "46.00"])
    end

    it "subtracts event-dated chargebacks in the quarter of the dispute event" do
      payload = perform_and_read(4, 2026)

      # Q4 2026 has no sales. Debit legs: the event-dated chargeback (100.00/20.00), the won
      # chargeback (100.00/20.00), and the partially refunded chargeback net of its refund
      # (60.00/12.00). The undated reversal emits NO leg (legacy treatment). Totals:
      # -(100 + 100 + 60) = -260.00 supplies, -(20 + 20 + 12) = -52.00 VAT.
      expect(payload[1]).to eq(["Austria", "Standard", "20.0", "-260.00", "-260.00", "-52.00", "-130.00", "-130.00", "-26.00"])
    end

    it "adds a won dispute back in the quarter of the dispute's won_at" do
      payload = perform_and_read(1, 2027)

      # Q1 2027 contains only the won chargeback's re-add leg: +100.00 supplies, +20.00 VAT.
      expect(payload[1]).to eq(["Austria", "Standard", "20.0", "100.00", "100.00", "20.00", "50.00", "50.00", "10.00"])
    end
  end
end
