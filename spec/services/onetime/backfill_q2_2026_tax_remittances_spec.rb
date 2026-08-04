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
    expect(hmrc.rail).to eq("wise")
    expect(hmrc.status).to eq("completed")
    expect(hmrc.transfer_id).to be_nil # left open for the Phase 3 rail sync to enrich

    # Every remittance's amounts and date, individually — a shared total or a
    # single spot-checked row can stay green while any other row is wrong
    # (gp#6990 review, nyomanjyotisa: all six passed with ATO's target wrong).
    expected = {
      "Irish Revenue (EU VAT OSS)" => [64_359_570, 56_393_915, Time.utc(2026, 7, 22)],
      "HMRC" => [24_456_761, 18_284_755, Time.utc(2026, 7, 22)],
      "Australian Taxation Office" => [7_614_969, 10_882_400, Time.utc(2026, 7, 22)],
      "Norwegian Tax Administration" => [2_094_888, 20_207_900, Time.utc(2026, 7, 18)],
      "Inland Revenue Department (NZ)" => [1_592_102, 2_737_221, Time.utc(2026, 7, 22)],
      "IRAS Singapore" => [1_023_136, 1_314_679, Time.utc(2026, 7, 31)],
    }
    expected.each do |authority, (usd_cents, target_cents, paid_at)|
      row = TaxRemittance.find_by!(authority:, period: "2026-Q2")
      expect(row.usd_amount_cents).to eq(usd_cents), "#{authority}: usd_amount_cents"
      expect(row.target_amount_cents).to eq(target_cents), "#{authority}: target_amount_cents"
      expect(row.paid_at).to eq(paid_at), "#{authority}: paid_at"
    end

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
