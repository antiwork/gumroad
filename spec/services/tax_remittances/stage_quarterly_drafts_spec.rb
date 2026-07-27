# frozen_string_literal: true

require "spec_helper"

describe TaxRemittances::StageQuarterlyDrafts do
  def create_taxed_purchase(product, attrs = {})
    gumroad_tax_cents = attrs.delete(:gumroad_tax_cents) || 0
    purchase = create(:purchase, link: product, **attrs)
    purchase.update_columns(gumroad_tax_cents:, total_transaction_cents: purchase.price_cents + gumroad_tax_cents)
    purchase
  end

  let(:period) { "2027-Q1" }
  let(:in_period) { Time.find_zone("UTC").local(2027, 2, 10) }
  let(:product) { create(:product, price_cents: 100_00, native_type: "digital") }

  before do
    travel_to(in_period) do
      create_taxed_purchase(product, country: "Germany", gumroad_tax_cents: 19_00)
      create_taxed_purchase(product, country: "France", gumroad_tax_cents: 20_00)
      create_taxed_purchase(product, country: "Australia", gumroad_tax_cents: 10_00)
    end
  end

  it "rejects a rail the tax_remittances table doesn't model" do
    expect { described_class.new(period, rail: "paypal") }.to raise_error(ArgumentError, /unknown rail/)
  end

  it "stages one draft per authority with the computed amount" do
    service = described_class.new(period).process

    expect(service.created.size).to eq(2)
    expect(service.skipped).to be_empty

    oss = TaxRemittance.find_by!(authority: "Irish Revenue (EU VAT OSS)", period:)
    expect(oss.usd_amount_cents).to eq(39_00) # Germany + France, one OSS payment
    expect(oss.jurisdiction).to eq("EU_OSS")
    expect(oss.currency).to eq("EUR")
    expect(oss.attempt).to eq(1)

    ato = TaxRemittance.find_by!(authority: "Australian Taxation Office", period:)
    expect(ato.usd_amount_cents).to eq(10_00)
    expect(ato.currency).to eq("AUD")
  end

  # Nothing this service creates may be capable of moving money on its own.
  it "creates every row as an unpaid draft" do
    described_class.new(period).process

    rows = TaxRemittance.for_period(period)
    expect(rows.map(&:status).uniq).to eq(["draft"])
    expect(rows.map(&:paid_at).compact).to be_empty
    expect(rows.map(&:transfer_id).compact).to be_empty
  end

  it "defaults to the Wise rail but accepts another one" do
    described_class.new(period).process
    expect(TaxRemittance.for_period(period).map(&:rail).uniq).to eq(["wise"])

    TaxRemittance.for_period(period).destroy_all

    described_class.new(period, rail: "stripe_global_payouts").process
    expect(TaxRemittance.for_period(period).map(&:rail).uniq).to eq(["stripe_global_payouts"])
  end

  it "records how each amount was derived so a reviewer needn't re-run the calculator" do
    described_class.new(period).process

    oss = TaxRemittance.find_by!(authority: "Irish Revenue (EU VAT OSS)", period:)
    expect(oss.notes).to include("Sales $39.00")
    expect(oss.notes).to include("net $39.00")
    expect(oss.notes).to include("DE, FR")
  end

  describe "re-running" do
    # Safe to run repeatedly as a quarter closes: a filing that already has a
    # draft must not get a second one.
    it "skips a filing that already has a draft rather than duplicating it" do
      described_class.new(period).process
      second = described_class.new(period).process

      expect(second.created).to be_empty
      expect(second.skipped.map { _1[:authority] }).to match_array(
        ["Irish Revenue (EU VAT OSS)", "Australian Taxation Office"]
      )
      expect(TaxRemittance.for_period(period).count).to eq(2)
    end

    # The strongest case: a filing already PAID must never be re-staged, or a
    # re-run at the wrong moment would propose paying an authority twice.
    it "never stages a filing that was already paid" do
      described_class.new(period).process
      oss = TaxRemittance.find_by!(authority: "Irish Revenue (EU VAT OSS)", period:)
      oss.update!(status: "pending_approval")
      oss.update!(status: "funded")
      oss.update!(status: "sent", paid_at: Time.current)
      oss.update!(status: "completed")

      service = described_class.new(period).process

      expect(service.created).to be_empty
      expect(service.skipped.find { _1[:authority] == "Irish Revenue (EU VAT OSS)" }[:reason])
        .to include("completed")
      expect(TaxRemittance.where(authority: "Irish Revenue (EU VAT OSS)", period:).count).to eq(1)
    end

    # A failed attempt is retryable, so staging continues the filing's
    # numbering instead of colliding on attempt 1 or restarting history.
    it "stages the next attempt after a failed one" do
      described_class.new(period).process
      TaxRemittance.find_by!(authority: "Australian Taxation Office", period:).update!(status: "failed")

      service = described_class.new(period).process

      staged = service.created.find { _1.authority == "Australian Taxation Office" }
      expect(staged.attempt).to eq(2)
      expect(staged.status).to eq("draft")
      # The failed attempt is preserved rather than overwritten.
      expect(TaxRemittance.where(authority: "Australian Taxation Office", period:).pluck(:status))
        .to match_array(%w[failed draft])
    end
  end

  describe "coverage gaps" do
    it "passes through countries with collected tax and no mapped authority" do
      travel_to(in_period) do
        create_taxed_purchase(product, country: "Canada", state: "ON", gumroad_tax_cents: 13_00)
      end

      service = described_class.new(period).process

      expect(service.coverage_gaps[:unmapped_countries]).to include(["CA", 13_00])
      # And no draft is invented for a country we have no authority for.
      expect(TaxRemittance.for_period(period).pluck(:jurisdiction)).not_to include("CA")
    end

    it "passes through country names that resolve to no country" do
      travel_to(in_period) do
        create_taxed_purchase(product, country: "Slovak Republic", gumroad_tax_cents: 8_00)
      end

      service = described_class.new(period).process

      expect(service.coverage_gaps[:unresolved_country_names]).to eq({ "Slovak Republic" => 8_00 })
    end

    # A purchase with no country at all can't be filed anywhere, so the amount
    # has to reach whoever runs this rather than staying inside the calculator.
    it "passes through tax on purchases with no country at all" do
      travel_to(in_period) do
        create_taxed_purchase(product, country: nil, ip_country: nil, gumroad_tax_cents: 6_00)
      end

      service = described_class.new(period).process

      expect(service.coverage_gaps[:countryless_tax_cents]).to eq(6_00)
      # And it is not invented as a payment to anyone.
      expect(service.created.sum { _1.usd_amount_cents }).to eq(39_00 + 10_00)
    end
  end

  it "stages nothing for a quarter with no collected tax" do
    service = described_class.new("2027-Q3").process

    expect(service.created).to be_empty
    expect(TaxRemittance.for_period("2027-Q3")).to be_empty
  end
end
