# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillAprilTaxRemittances do
  it "creates all seven April 2026 remittances as completed Wise payments" do
    service = described_class.new.process

    expect(service.created.size).to eq(7)
    expect(service.skipped).to be_empty
    expect(TaxRemittance.count).to eq(7)

    hmrc = TaxRemittance.find_by!(authority: "HMRC", period: "2026-Q1")
    expect(hmrc.jurisdiction).to eq("GB")
    expect(hmrc.currency).to eq("GBP")
    expect(hmrc.usd_amount_cents).to eq(25_333_498)
    expect(hmrc.rail).to eq("wise")
    expect(hmrc.status).to eq("completed")
    expect(hmrc.paid_at).to be_present
    expect(hmrc.target_amount_cents).to be_nil

    oss = TaxRemittance.find_by!(jurisdiction: "EU_OSS", period: "2026-Q1")
    expect(oss.usd_amount_cents).to eq(70_308_965)

    total = TaxRemittance.for_period("2026-Q1").sum(:usd_amount_cents)
    expect(total).to eq(110_804_883) # ~$1.108M, matching the QBO GL April total
  end

  it "is idempotent" do
    described_class.new.process
    second = described_class.new.process

    expect(second.created).to be_empty
    expect(second.skipped.size).to eq(7)
    expect(TaxRemittance.count).to eq(7)
  end
end
