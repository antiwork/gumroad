# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillQ22026TaxRemittances do
  it "creates the six Wise-confirmed Q2 2026 remittances as completed, with target amounts" do
    service = described_class.new.process

    expect(service.created.size).to eq(6)
    expect(service.skipped).to be_empty
    expect(TaxRemittance.count).to eq(6)

    hmrc = TaxRemittance.find_by!(authority: "HMRC", period: "2026-Q2")
    expect(hmrc.jurisdiction).to eq("GB")
    expect(hmrc.currency).to eq("GBP")
    expect(hmrc.usd_amount_cents).to eq(24_456_761)
    expect(hmrc.target_amount_cents).to eq(18_284_755)
    expect(hmrc.rail).to eq("wise")
    expect(hmrc.status).to eq("completed")
    expect(hmrc.paid_at).to eq(Time.utc(2026, 7, 22))
    expect(hmrc.transfer_id).to be_nil # left open for the Phase 3 rail sync to enrich

    oss = TaxRemittance.find_by!(jurisdiction: "EU_OSS", period: "2026-Q2")
    expect(oss.usd_amount_cents).to eq(64_359_570)

    total = TaxRemittance.for_period("2026-Q2").sum(:usd_amount_cents)
    expect(total).to eq(101_141_426) # ~$1.01M across the six confirmed Q2 sends, matching the 2026-08-03 rail read
  end

  it "does not touch Switzerland — it is already recorded from the API-initiated Phase 4 payment" do
    swiss = create(:tax_remittance, authority: "Eidgenössisches Finanzdepartement (Swiss VAT)",
                                    jurisdiction: "CH", currency: "CHF", period: "2026-Q2",
                                    usd_amount_cents: 1_764_164, target_amount_cents: 1_429_414,
                                    status: "funded")

    described_class.new.process

    expect(swiss.reload.status).to eq("funded") # untouched
    expect(TaxRemittance.where(authority: swiss.authority, period: "2026-Q2").count).to eq(1)
  end

  it "is idempotent" do
    described_class.new.process
    second = described_class.new.process

    expect(second.created).to be_empty
    expect(second.skipped.size).to eq(6)
    expect(TaxRemittance.count).to eq(6)
  end

  it "raises when an existing row conflicts with the backfill data" do
    create(:tax_remittance, :completed, period: "2026-Q2", usd_amount_cents: 1) # wrong amount

    expect { described_class.new.process }.to raise_error(/HMRC 2026-Q2 row conflicts/)
  end

  it "does not mistake a later attempt for the historical first payment" do
    later_attempt = create(:tax_remittance, :failed, period: "2026-Q2", attempt: 2)

    service = described_class.new.process

    expect(service.created.size).to eq(6)
    hmrc_first = TaxRemittance.find_by!(authority: "HMRC", period: "2026-Q2", attempt: 1)
    expect(hmrc_first.status).to eq("completed")
    expect(later_attempt.reload.attempt).to eq(2)
  end

  it "raises a descriptive error when a later attempt is live and attempt 1 is missing" do
    create(:tax_remittance, status: "draft", period: "2026-Q2", attempt: 2)

    expect { described_class.new.process }.to raise_error(/HMRC 2026-Q2 has a live attempt 2 \(status draft\)/)
    expect(TaxRemittance.find_by(authority: "HMRC", period: "2026-Q2", attempt: 1)).to be_nil
  end
end
