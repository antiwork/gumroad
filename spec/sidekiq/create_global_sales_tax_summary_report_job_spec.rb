# frozen_string_literal: true

require "spec_helper"

describe CreateGlobalSalesTaxSummaryReportJob do
  let(:month) { 1 }
  let(:year) { 2024 }

  it "raises an argument error if the year is out of bounds" do
    expect { described_class.new.perform(month, 2013) }.to raise_error(ArgumentError)
  end

  it "raises an argument error if the month is out of bounds" do
    expect { described_class.new.perform(13, year) }.to raise_error(ArgumentError)
  end

  describe "report generation" do
    let(:s3_bucket_double) do
      s3_bucket_double = double
      allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket).and_return(s3_bucket_double)
      s3_bucket_double
    end

    before :context do
      @s3_object = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/global-sales-tax-summary-spec-#{SecureRandom.hex(18)}.csv")
    end

    def read_csv_from_s3
      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      CSV.read(temp_file)
    end

    def create_taxed_purchase(product, attrs = {})
      gumroad_tax_cents = attrs.delete(:gumroad_tax_cents) || 0
      purchase = create(:purchase, link: product, **attrs)
      purchase.update_columns(gumroad_tax_cents: gumroad_tax_cents, total_transaction_cents: purchase.price_cents + gumroad_tax_cents)
      purchase
    end

    describe "with purchases across multiple countries" do
      before do
        travel_to(Time.find_zone("UTC").local(2024, 1, 15)) do
          product = create(:product, price_cents: 100_00, native_type: "digital")

          create_taxed_purchase(product, country: "United States", zip_code: "98121", gumroad_tax_cents: 1000)
          create_taxed_purchase(product, country: "United States", zip_code: "53703", gumroad_tax_cents: 800)
          create_taxed_purchase(product, country: "United States", zip_code: "98184", gumroad_tax_cents: 1000)
          create_taxed_purchase(product, country: "Canada", state: "ON", ip_country: "Canada", gumroad_tax_cents: 1300)
          create_taxed_purchase(product, country: "Canada", state: "QC", ip_country: "Canada", gumroad_tax_cents: 1498)
          create_taxed_purchase(product, country: "India", ip_state: "KA", gumroad_tax_cents: 1800)
          create_taxed_purchase(product, country: "Germany", gumroad_tax_cents: 1900)
          create_taxed_purchase(product, country: "Australia", gumroad_tax_cents: 1000)
        end
      end

      it "creates a summary CSV with correct headers, country/state breakdown, and sends email" do
        expect(s3_bucket_double).to receive(:object).and_return(@s3_object)

        described_class.new.perform(month, year)

        actual_payload = read_csv_from_s3

        expect(actual_payload[0]).to eq(["Country", "State/Province", "GMV", "Number of orders", "Sales tax collected"])

        countries_in_csv = actual_payload[1..].map { |row| [row[0], row[1]] }
        expect(countries_in_csv).to eq(countries_in_csv.sort)

        au_row = actual_payload.find { |row| row[0] == "Australia" }
        expect(au_row).to be_present
        expect(au_row[1]).to eq("")
        expect(au_row[3]).to eq("1")

        ca_on_row = actual_payload.find { |row| row[0] == "Canada" && row[1] == "ON" }
        expect(ca_on_row).to be_present
        expect(ca_on_row[3]).to eq("1")

        ca_qc_row = actual_payload.find { |row| row[0] == "Canada" && row[1] == "QC" }
        expect(ca_qc_row).to be_present
        expect(ca_qc_row[3]).to eq("1")

        de_row = actual_payload.find { |row| row[0] == "Germany" }
        expect(de_row).to be_present
        expect(de_row[1]).to eq("")

        in_row = actual_payload.find { |row| row[0] == "India" && row[1] == "KA" }
        expect(in_row).to be_present
        expect(in_row[3]).to eq("1")

        us_wa_row = actual_payload.find { |row| row[0] == "United States" && row[1] == "WA" }
        expect(us_wa_row).to be_present
        expect(us_wa_row[3]).to eq("2")

        us_wi_row = actual_payload.find { |row| row[0] == "United States" && row[1] == "WI" }
        expect(us_wi_row).to be_present
        expect(us_wi_row[3]).to eq("1")

        expect(ActionMailer::Base.deliveries.last.subject).to eq("Global Sales Tax Summary Report for 1/2024")
        expect(ActionMailer::Base.deliveries.last.to).to eq(["salestax@gumroad.com"])
        expect(ActionMailer::Base.deliveries.last.cc).to eq(["steven.olson@gumroad.com"])
      end
    end

    describe "country normalization" do
      before do
        travel_to(Time.find_zone("UTC").local(2024, 1, 15)) do
          product = create(:product, price_cents: 100_00, native_type: "digital")
          create_taxed_purchase(product, country: "Korea, Republic of", gumroad_tax_cents: 1000)
        end
      end

      it "normalizes country names using common_name" do
        expect(s3_bucket_double).to receive(:object).and_return(@s3_object)

        described_class.new.perform(month, year)

        actual_payload = read_csv_from_s3

        kr_row = actual_payload.find { |row| row[0] == "South Korea" }
        expect(kr_row).to be_present
        expect(kr_row[3]).to eq("1")
      end
    end

    describe "null country fallback" do
      before do
        travel_to(Time.find_zone("UTC").local(2024, 1, 15)) do
          product = create(:product, price_cents: 100_00, native_type: "digital")
          create_taxed_purchase(product, country: nil, ip_country: "Germany", gumroad_tax_cents: 1900)
        end
      end

      it "falls back to ip_country when country is nil" do
        expect(s3_bucket_double).to receive(:object).and_return(@s3_object)

        described_class.new.perform(month, year)

        actual_payload = read_csv_from_s3

        de_row = actual_payload.find { |row| row[0] == "Germany" }
        expect(de_row).to be_present
        expect(de_row[3]).to eq("1")
      end
    end

    describe "unknown country" do
      before do
        travel_to(Time.find_zone("UTC").local(2024, 1, 15)) do
          product = create(:product, price_cents: 100_00, native_type: "digital")
          create_taxed_purchase(product, country: nil, ip_country: nil, gumroad_tax_cents: 500)
        end
      end

      it "groups purchases with no country as Unknown" do
        expect(s3_bucket_double).to receive(:object).and_return(@s3_object)

        described_class.new.perform(month, year)

        actual_payload = read_csv_from_s3

        unknown_row = actual_payload.find { |row| row[0] == "Unknown" }
        expect(unknown_row).to be_present
        expect(unknown_row[3]).to eq("1")
      end
    end

    describe "refund handling", :vcr do
      before do
        travel_to(Time.find_zone("UTC").local(2024, 1, 15)) do
          product = create(:product, price_cents: 100_00, native_type: "digital")

          @partial_refund_purchase = create(:purchase_in_progress, link: product, country: "Germany")
          @partial_refund_purchase.chargeable = create(:chargeable)
          @partial_refund_purchase.process!
          @partial_refund_purchase.update_balance_and_mark_successful!
          @partial_refund_purchase.update_columns(gumroad_tax_cents: 1900, total_transaction_cents: @partial_refund_purchase.price_cents + 1900)

          refund_flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 30_00)
          @partial_refund_purchase.refund_purchase!(refund_flow_of_funds, nil)
        end
      end

      it "uses net-of-refunds amounts for partially refunded purchases" do
        expect(s3_bucket_double).to receive(:object).and_return(@s3_object)

        described_class.new.perform(month, year)

        actual_payload = read_csv_from_s3

        de_row = actual_payload.find { |row| row[0] == "Germany" }
        expect(de_row).to be_present

        gmv = BigDecimal(de_row[2].delete(","))
        expect(gmv).to be < BigDecimal("119.00")
      end
    end

    describe "excluded purchases" do
      before do
        travel_to(Time.find_zone("UTC").local(2024, 1, 15)) do
          product = create(:product, price_cents: 100_00, native_type: "digital")

          fully_refunded = create(:purchase, link: product, country: "Germany")
          fully_refunded.update_columns(gumroad_tax_cents: 1900, total_transaction_cents: fully_refunded.price_cents + 1900, stripe_refunded: true)

          create(:purchase, link: product, country: "France")

          create_taxed_purchase(product, country: "Australia", gumroad_tax_cents: 1000)
        end
      end

      it "excludes fully refunded and zero-tax purchases" do
        expect(s3_bucket_double).to receive(:object).and_return(@s3_object)

        described_class.new.perform(month, year)

        actual_payload = read_csv_from_s3

        expect(actual_payload.find { |row| row[0] == "France" }).to be_nil
        expect(actual_payload.find { |row| row[0] == "Germany" }).to be_nil

        au_row = actual_payload.find { |row| row[0] == "Australia" }
        expect(au_row).to be_present
      end
    end

    describe "US state resolution via IP fallback" do
      before do
        travel_to(Time.find_zone("UTC").local(2024, 1, 15)) do
          product = create(:product, price_cents: 100_00, native_type: "digital")
          create_taxed_purchase(product, country: "United States", zip_code: nil, gumroad_tax_cents: 1000)
        end
      end

      it "falls back to GeoIp lookup when zip code is missing" do
        geo_result = double(region_name: "CA")
        allow(GeoIp).to receive(:lookup).and_return(geo_result)
        expect(s3_bucket_double).to receive(:object).and_return(@s3_object)

        described_class.new.perform(month, year)

        actual_payload = read_csv_from_s3

        us_ca_row = actual_payload.find { |row| row[0] == "United States" && row[1] == "CA" }
        expect(us_ca_row).to be_present
      end
    end

    describe "Canada province via ip_state fallback" do
      before do
        travel_to(Time.find_zone("UTC").local(2024, 1, 15)) do
          product = create(:product, price_cents: 100_00, native_type: "digital")
          create_taxed_purchase(product, country: "Canada", state: nil, ip_state: "BC", ip_country: "Canada", gumroad_tax_cents: 1200)
        end
      end

      it "falls back to ip_state for Canada province" do
        expect(s3_bucket_double).to receive(:object).and_return(@s3_object)

        described_class.new.perform(month, year)

        actual_payload = read_csv_from_s3

        ca_bc_row = actual_payload.find { |row| row[0] == "Canada" && row[1] == "BC" }
        expect(ca_bc_row).to be_present
      end
    end

    describe "India state with invalid ip_state" do
      before do
        travel_to(Time.find_zone("UTC").local(2024, 1, 15)) do
          product = create(:product, price_cents: 100_00, native_type: "digital")
          create_taxed_purchase(product, country: "India", ip_state: "12345", gumroad_tax_cents: 1800)
        end
      end

      it "uses empty state when ip_state is invalid for India" do
        expect(s3_bucket_double).to receive(:object).and_return(@s3_object)

        described_class.new.perform(month, year)

        actual_payload = read_csv_from_s3

        in_row = actual_payload.find { |row| row[0] == "India" }
        expect(in_row).to be_present
        expect(in_row[1]).to eq("")
      end
    end

    describe "GMV and tax formatting" do
      before do
        travel_to(Time.find_zone("UTC").local(2024, 1, 15)) do
          product = create(:product, price_cents: 100_00, native_type: "digital")
          create_taxed_purchase(product, country: "Germany", gumroad_tax_cents: 1900)
        end
      end

      it "formats monetary values with cents" do
        expect(s3_bucket_double).to receive(:object).and_return(@s3_object)

        described_class.new.perform(month, year)

        actual_payload = read_csv_from_s3

        de_row = actual_payload.find { |row| row[0] == "Germany" }
        expect(de_row[2]).to match(/\d+\.\d{2}/)
        expect(de_row[4]).to match(/\d+\.\d{2}/)
      end
    end
  end
end
