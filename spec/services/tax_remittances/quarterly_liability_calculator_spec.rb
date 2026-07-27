# frozen_string_literal: true

require "spec_helper"

describe TaxRemittances::QuarterlyLiabilityCalculator do
  # Mirrors the helper the global sales tax summary report spec uses: taxed
  # purchases need gumroad_tax_cents written directly, since the tax
  # calculator won't assign it for arbitrary spec countries.
  def create_taxed_purchase(product, attrs = {})
    gumroad_tax_cents = attrs.delete(:gumroad_tax_cents) || 0
    purchase = create(:purchase, link: product, **attrs)
    purchase.update_columns(gumroad_tax_cents:, total_transaction_cents: purchase.price_cents + gumroad_tax_cents)
    purchase
  end

  # A quarter safely after both reporting cutovers, so purchases created in it
  # use the current (event-dated) attribution rules rather than the legacy
  # netting kept for historical periods.
  let(:period) { "2027-Q1" }
  let(:in_period) { Time.find_zone("UTC").local(2027, 2, 10) }
  let(:product) { create(:product, price_cents: 100_00, native_type: "digital") }

  def liability_for(calculator, authority)
    calculator.liabilities.find { |liability| liability.authority == authority }
  end

  describe "period validation" do
    it "rejects a period that isn't a quarter string" do
      expect { described_class.new("2027-02") }.to raise_error(ArgumentError, /must look like/)
      expect { described_class.new("2027-Q5") }.to raise_error(ArgumentError)
      expect { described_class.new(nil) }.to raise_error(ArgumentError)
    end

    it "derives the calendar quarter boundaries" do
      range = described_class.new("2027-Q3").period_range

      expect(range.first).to eq(Time.find_zone("UTC").local(2027, 7, 1).beginning_of_day)
      expect(range.last.to_date).to eq(Date.new(2027, 9, 30))
    end
  end

  describe "authority routing" do
    it "remits every EU member state's tax to Irish Revenue under the one-stop-shop" do
      mapping = described_class.authority_by_country_code

      expect(mapping["DE"]).to eq("Irish Revenue (EU VAT OSS)")
      expect(mapping["FR"]).to eq("Irish Revenue (EU VAT OSS)")
      expect(mapping["IE"]).to eq("Irish Revenue (EU VAT OSS)")
    end

    # The UK sits in EU_VAT_APPLICABLE_COUNTRY_CODES for rate-collection
    # reasons, but its VAT is filed with HMRC, not through the OSS return.
    # Routing it into the EU bucket would send UK VAT to Dublin.
    it "files the UK with HMRC rather than folding it into the EU return" do
      expect(described_class.authority_by_country_code["GB"]).to eq("HMRC")
      expect(described_class.eu_oss_country_codes).not_to include("GB")
    end

    it "routes each single-country authority to its own jurisdiction" do
      mapping = described_class.authority_by_country_code

      expect(mapping["AU"]).to eq("Australian Taxation Office")
      expect(mapping["NO"]).to eq("Norwegian Tax Administration")
      expect(mapping["NZ"]).to eq("Inland Revenue Department (NZ)")
      expect(mapping["CH"]).to eq("Eidgenössisches Finanzdepartement (Swiss VAT)")
      expect(mapping["SG"]).to eq("IRAS Singapore")
    end

    # Every authority this calculator can produce has to exist in the model's
    # metadata, or building a remittance row for it would blow up on a missing
    # jurisdiction/currency at the moment we try to record a real payment.
    it "only names authorities the tax_remittances model knows" do
      expect(described_class.authority_by_country_code.values.uniq)
        .to all(be_in(TaxRemittance::KNOWN_AUTHORITIES.keys))
    end
  end

  describe "computing a quarter's liability" do
    before do
      travel_to(in_period) do
        create_taxed_purchase(product, country: "Germany", gumroad_tax_cents: 19_00)
        create_taxed_purchase(product, country: "France", gumroad_tax_cents: 20_00)
        create_taxed_purchase(product, country: "United Kingdom", gumroad_tax_cents: 20_00)
        create_taxed_purchase(product, country: "Australia", gumroad_tax_cents: 10_00)
        create_taxed_purchase(product, country: "Singapore", gumroad_tax_cents: 9_00)
      end
    end

    it "sums EU member states into one Irish Revenue payment and keeps the others separate" do
      calculator = described_class.new(period).process

      oss = liability_for(calculator, "Irish Revenue (EU VAT OSS)")
      expect(oss.tax_collected_cents).to eq(39_00) # Germany 19.00 + France 20.00
      expect(oss.jurisdiction).to eq("EU_OSS")
      expect(oss.currency).to eq("EUR")
      expect(oss.country_codes).to eq(%w[DE FR])

      hmrc = liability_for(calculator, "HMRC")
      expect(hmrc.tax_collected_cents).to eq(20_00)
      expect(hmrc.currency).to eq("GBP")
      expect(hmrc.country_codes).to eq(["GB"])

      expect(liability_for(calculator, "Australian Taxation Office").tax_collected_cents).to eq(10_00)
      expect(liability_for(calculator, "IRAS Singapore").tax_collected_cents).to eq(9_00)
    end

    it "orders authorities by amount owed, largest first" do
      calculator = described_class.new(period).process

      amounts = calculator.liabilities.map(&:tax_collected_cents)
      expect(amounts).to eq(amounts.sort.reverse)
      expect(calculator.total_usd_cents).to eq(78_00)
    end

    it "ignores purchases outside the quarter" do
      travel_to(in_period + 3.months) do
        create_taxed_purchase(product, country: "Germany", gumroad_tax_cents: 99_00)
      end

      calculator = described_class.new(period).process

      expect(liability_for(calculator, "Irish Revenue (EU VAT OSS)").tax_collected_cents).to eq(39_00)
    end

    it "ignores purchases that collected no Gumroad tax" do
      travel_to(in_period) { create_taxed_purchase(product, country: "Germany", gumroad_tax_cents: 0) }

      calculator = described_class.new(period).process

      expect(liability_for(calculator, "Irish Revenue (EU VAT OSS)").tax_collected_cents).to eq(39_00)
    end

    it "falls back to the GeoIP country when the purchase has no billing country" do
      travel_to(in_period) do
        create_taxed_purchase(product, country: nil, ip_country: "Australia", gumroad_tax_cents: 5_00)
      end

      calculator = described_class.new(period).process

      expect(liability_for(calculator, "Australian Taxation Office").tax_collected_cents).to eq(15_00)
    end

    it "resolves alternate country spellings to the same authority" do
      travel_to(in_period) do
        # The ISO short name for Czechia, rather than the common name.
        create_taxed_purchase(product, country: "Czech Republic", gumroad_tax_cents: 7_00)
      end

      calculator = described_class.new(period).process

      oss = liability_for(calculator, "Irish Revenue (EU VAT OSS)")
      expect(oss.tax_collected_cents).to eq(46_00)
      expect(oss.country_codes).to include("CZ")
    end
  end

  describe "refunds" do
    before do
      travel_to(in_period) do
        @purchase = create_taxed_purchase(product, country: "Australia", gumroad_tax_cents: 10_00)
      end
    end

    it "subtracts a refund issued inside the quarter" do
      travel_to(in_period + 5.days) do
        create(:refund, purchase: @purchase, total_transaction_cents: 50_00, gumroad_tax_cents: 4_00)
      end

      calculator = described_class.new(period).process

      liability = liability_for(calculator, "Australian Taxation Office")
      expect(liability.sales_tax_cents).to eq(10_00)
      expect(liability.refunded_tax_cents).to eq(4_00)
      expect(liability.tax_collected_cents).to eq(6_00)
    end

    # A refund is a correction in the period it happens, matching how it is
    # reported on the return — so a later-quarter refund must not reduce this
    # quarter's payment (it reduces the next one).
    it "leaves the quarter untouched when the refund lands in a later quarter" do
      travel_to(in_period + 4.months) do
        create(:refund, purchase: @purchase, total_transaction_cents: 50_00, gumroad_tax_cents: 4_00)
      end

      calculator = described_class.new(period).process

      expect(liability_for(calculator, "Australian Taxation Office").tax_collected_cents).to eq(10_00)
    end

    it "drops an authority whose refunds exceed its collections for the quarter" do
      travel_to(in_period + 5.days) do
        create(:refund, purchase: @purchase, total_transaction_cents: 119_00, gumroad_tax_cents: 12_00)
      end

      calculator = described_class.new(period).process

      # Nothing is owed, so no payment is proposed — the credit is carried on
      # the next return rather than sent as a negative transfer.
      expect(liability_for(calculator, "Australian Taxation Office")).to be_nil
      expect(calculator.total_usd_cents).to eq(0)
    end
  end

  describe "chargebacks" do
    let(:cutover) { Purchase::Reportable::CHARGEBACK_REPORTING_CUTOVER.beginning_of_day }

    before do
      travel_to(in_period) do
        @purchase = create_taxed_purchase(product, country: "Norway", gumroad_tax_cents: 25_00)
      end
    end

    it "subtracts a chargeback formalized inside the quarter" do
      event_time = in_period + 10.days
      @purchase.update!(chargeback_date: event_time)
      create(:dispute, purchase: @purchase, event_created_at: event_time)

      calculator = described_class.new(period).process

      # The clawback cancels the sale exactly, so nothing is owed and no
      # payment is proposed for the authority at all.
      expect(liability_for(calculator, "Norwegian Tax Administration")).to be_nil
      expect(calculator.total_usd_cents).to eq(0)
    end

    it "still owes the remainder when only part of the quarter's tax is charged back" do
      travel_to(in_period) do
        create_taxed_purchase(product, country: "Norway", gumroad_tax_cents: 40_00)
      end
      event_time = in_period + 10.days
      @purchase.update!(chargeback_date: event_time)
      create(:dispute, purchase: @purchase, event_created_at: event_time)

      calculator = described_class.new(period).process

      liability = liability_for(calculator, "Norwegian Tax Administration")
      # Both purchases collected tax (25.00 + 40.00); only the first was
      # charged back, so its 25.00 comes back off and the rest is still owed.
      expect(liability.sales_tax_cents).to eq(65_00)
      expect(liability.chargeback_tax_cents).to eq(25_00)
      expect(liability.tax_collected_cents).to eq(40_00)
    end

    it "nets a chargeback and its win back to the original amount when both land in the quarter" do
      event_time = in_period + 10.days
      won_time = in_period + 20.days

      @purchase.update!(chargeback_date: event_time)
      travel_to(won_time) do
        @purchase.update!(chargeback_reversed: true)
        create(:dispute, purchase: @purchase, state: "won", event_created_at: event_time, won_at: Time.current)
      end

      calculator = described_class.new(period).process

      # Debit and re-add cancel: the sale stands, so the full tax is owed.
      liability = liability_for(calculator, "Norwegian Tax Administration")
      expect(liability.chargeback_tax_cents).to eq(0)
      expect(liability.tax_collected_cents).to eq(25_00)
    end
  end

  describe "coverage gaps" do
    it "reports countries where tax was collected but no authority is mapped" do
      travel_to(in_period) do
        # Canada's tax is filed separately (not through this rail), so it is a
        # known-expected gap — but it must be VISIBLE rather than dropped.
        create_taxed_purchase(product, country: "Canada", state: "ON", gumroad_tax_cents: 13_00)
        create_taxed_purchase(product, country: "Australia", gumroad_tax_cents: 10_00)
      end

      calculator = described_class.new(period).process

      expect(calculator.unmapped_countries["CA"]).to eq(13_00)
      expect(calculator.unmapped_country_report.first).to eq(["CA", 13_00])
      # And it stays out of the amounts we actually remit.
      expect(calculator.total_usd_cents).to eq(10_00)
    end

    it "does not flag an unmapped country whose collections net to nothing" do
      travel_to(in_period) do
        @canadian = create_taxed_purchase(product, country: "Canada", state: "ON", gumroad_tax_cents: 13_00)
      end
      travel_to(in_period + 5.days) do
        create(:refund, purchase: @canadian, total_transaction_cents: 113_00, gumroad_tax_cents: 13_00)
      end

      calculator = described_class.new(period).process

      expect(calculator.unmapped_countries).to be_empty
    end

    it "ignores purchases with no resolvable country at all" do
      travel_to(in_period) do
        create_taxed_purchase(product, country: nil, ip_country: nil, gumroad_tax_cents: 5_00)
      end

      calculator = described_class.new(period).process

      expect(calculator.liabilities).to be_empty
      expect(calculator.unmapped_countries).to be_empty
      expect(calculator.unresolved_country_names).to be_empty
    end

    # ISO name matching is not exhaustive, so a country name we can't resolve
    # would otherwise silently drop the tax collected against it. That must be
    # visible: here the output is money we send, not a CSV a human reads.
    it "reports a country name that resolves to no country, with the tax at stake" do
      travel_to(in_period) do
        create_taxed_purchase(product, country: "Slovak Republic", gumroad_tax_cents: 8_00)
        create_taxed_purchase(product, country: "Australia", gumroad_tax_cents: 10_00)
      end

      calculator = described_class.new(period).process

      expect(calculator.unresolved_country_names).to eq({ "Slovak Republic" => 8_00 })
      # And it does not leak into any authority's payment.
      expect(calculator.total_usd_cents).to eq(10_00)
    end
  end

  describe "consistency with the filed report" do
    # The whole point of reusing the report's scopes is that we remit what we
    # file. This pins the invariant: for a quarter, the per-country tax the
    # calculator computes must equal what the report's own aggregation would
    # produce for those same countries.
    it "matches the global sales tax summary report's tax figures country by country" do
      travel_to(in_period) do
        create_taxed_purchase(product, country: "Germany", gumroad_tax_cents: 19_00)
        create_taxed_purchase(product, country: "United Kingdom", gumroad_tax_cents: 20_00)
        @refunded = create_taxed_purchase(product, country: "Australia", gumroad_tax_cents: 10_00)
      end
      travel_to(in_period + 5.days) do
        create(:refund, purchase: @refunded, total_transaction_cents: 50_00, gumroad_tax_cents: 4_00)
      end

      calculator = described_class.new(period).process

      # Rebuild the same figures straight from the report's scopes, summed over
      # the quarter instead of a month, and compare per authority.
      expected = {
        "Irish Revenue (EU VAT OSS)" => 19_00,
        "HMRC" => 20_00,
        "Australian Taxation Office" => 6_00,
      }

      actual = calculator.liabilities.to_h { |liability| [liability.authority, liability.tax_collected_cents] }
      expect(actual).to eq(expected)
    end
  end
end
