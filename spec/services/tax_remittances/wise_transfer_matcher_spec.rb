# frozen_string_literal: true

require "spec_helper"

describe TaxRemittances::WiseTransferMatcher do
  let(:hmrc_transfer) do
    { id: 900_001, status: "outgoing_payment_sent", targetCurrency: "GBP",
      targetValue: 182_847.55, sourceValue: 244_567.61, created: "2026-07-22 10:00:00" }
  end
  let(:cancelled_sibling) do
    { id: 900_002, status: "cancelled", targetCurrency: "GBP",
      targetValue: 182_800.00, sourceValue: 244_500.00, created: "2026-07-22 09:00:00" }
  end

  it "matches a transfer to a paid, unenriched remittance by target amount and writes transfer_id" do
    hmrc = create(:tax_remittance, :completed, authority: "HMRC", jurisdiction: "GB", currency: "GBP",
                                               period: "2026-Q2", usd_amount_cents: 24_456_761,
                                               target_amount_cents: 18_284_755, paid_at: Time.utc(2026, 7, 22),
                                               transfer_id: nil)

    result = described_class.new("2026-Q2").process([hmrc_transfer, cancelled_sibling])

    expect(result.matched.size).to eq(1)
    expect(result.matched.first.remittance).to eq(hmrc)
    expect(hmrc.reload.transfer_id).to eq("900001")
  end

  it "ignores cancelled transfers — Wise's cancel-and-resend pattern must not double-match" do
    hmrc = create(:tax_remittance, :completed, currency: "GBP", period: "2026-Q2",
                                               target_amount_cents: 18_284_755, paid_at: Time.utc(2026, 7, 22),
                                               transfer_id: nil)

    result = described_class.new("2026-Q2").process([cancelled_sibling])

    expect(result.matched).to be_empty
    expect(result.unmatched).to eq([hmrc])
  end

  it "falls back to usd_amount_cents when target_amount_cents is nil (April-style backfill rows)" do
    remittance = create(:tax_remittance, :completed, currency: "GBP", period: "2026-Q1",
                                                     usd_amount_cents: 25_333_498, target_amount_cents: nil,
                                                     paid_at: Time.utc(2026, 4, 28), transfer_id: nil)
    transfer = { id: 700_001, status: "outgoing_payment_sent", targetCurrency: "GBP",
                 targetValue: 20_000.00, sourceValue: 253_334.98, created: "2026-04-28 12:00:00" }

    result = described_class.new("2026-Q1").process([transfer])

    expect(result.matched.map(&:remittance)).to eq([remittance])
    expect(remittance.reload.transfer_id).to eq("700001")
  end

  it "reports ambiguous rather than guessing when two transfers tie on amount" do
    hmrc = create(:tax_remittance, :completed, currency: "GBP", period: "2026-Q2",
                                               target_amount_cents: 18_284_755, paid_at: Time.utc(2026, 7, 22),
                                               transfer_id: nil)
    duplicate = hmrc_transfer.merge(id: 900_003)

    result = described_class.new("2026-Q2").process([hmrc_transfer, duplicate])

    expect(result.matched).to be_empty
    expect(result.ambiguous.size).to eq(1)
    expect(result.ambiguous.first.remittance).to eq(hmrc)
    expect(result.ambiguous.first.candidates.map { |c| c[:id] }).to contain_exactly(900_001, 900_003)
    expect(hmrc.reload.transfer_id).to be_nil
  end

  it "excludes rows that already have a transfer_id — nothing left to enrich" do
    create(:tax_remittance, :completed, currency: "GBP", period: "2026-Q2",
                                        target_amount_cents: 18_284_755, paid_at: Time.utc(2026, 7, 22),
                                        transfer_id: "already-set")

    result = described_class.new("2026-Q2").process([hmrc_transfer])

    expect(result.matched).to be_empty
    expect(result.unmatched).to be_empty
  end

  it "excludes rows with no paid_at — nothing has been sent yet, there's no transfer to find" do
    create(:tax_remittance, currency: "GBP", period: "2026-Q2", status: "draft",
                            target_amount_cents: 18_284_755, paid_at: nil, transfer_id: nil)

    result = described_class.new("2026-Q2").process([hmrc_transfer])

    expect(result.matched).to be_empty
    expect(result.unmatched).to be_empty
  end

  it "does not write transfer_id when enrich: false — dry run" do
    hmrc = create(:tax_remittance, :completed, currency: "GBP", period: "2026-Q2",
                                               target_amount_cents: 18_284_755, paid_at: Time.utc(2026, 7, 22),
                                               transfer_id: nil)

    result = described_class.new("2026-Q2").process([hmrc_transfer], enrich: false)

    expect(result.matched.size).to eq(1)
    expect(hmrc.reload.transfer_id).to be_nil
  end

  it "matches transfers parsed from JSON with String keys (the shape a live GET /v1/transfers read produces)" do
    hmrc = create(:tax_remittance, :completed, currency: "GBP", period: "2026-Q2",
                                               target_amount_cents: 18_284_755, paid_at: Time.utc(2026, 7, 22),
                                               transfer_id: nil)
    string_keyed = JSON.parse(hmrc_transfer.to_json)

    result = described_class.new("2026-Q2").process([string_keyed])

    expect(result.matched.size).to eq(1)
    expect(hmrc.reload.transfer_id).to eq("900001")
  end

  it "does not assign one transfer to two remittances that each uniquely match it" do
    hmrc = create(:tax_remittance, :completed, authority: "HMRC", currency: "GBP", period: "2026-Q2",
                                               target_amount_cents: 18_284_755, paid_at: Time.utc(2026, 7, 22),
                                               transfer_id: nil)
    other = create(:tax_remittance, :completed, authority: "IE Revenue", currency: "GBP", period: "2026-Q2",
                                                target_amount_cents: 18_284_755, paid_at: Time.utc(2026, 7, 23),
                                                transfer_id: nil)

    result = described_class.new("2026-Q2").process([hmrc_transfer])

    expect(result.matched).to be_empty
    expect(result.ambiguous.map(&:remittance)).to contain_exactly(hmrc, other)
    expect(hmrc.reload.transfer_id).to be_nil
    expect(other.reload.transfer_id).to be_nil
  end

  it "rejects a transfer outside the date window" do
    create(:tax_remittance, :completed, currency: "GBP", period: "2026-Q2",
                                        target_amount_cents: 18_284_755, paid_at: Time.utc(2026, 7, 1),
                                        transfer_id: nil)
    far_transfer = hmrc_transfer.merge(created: "2026-07-22 10:00:00") # 21 days later

    result = described_class.new("2026-Q2").process([far_transfer])

    expect(result.matched).to be_empty
    expect(result.unmatched.size).to eq(1)
  end

  it "reports a sent transfer no remittance ever candidated for as unclaimed, instead of dropping it" do
    create(:tax_remittance, :completed, currency: "GBP", period: "2026-Q2",
                                        target_amount_cents: 18_284_755, paid_at: Time.utc(2026, 7, 22),
                                        transfer_id: nil)
    stray = { id: 900_099, status: "outgoing_payment_sent", targetCurrency: "EUR",
              targetValue: 999.00, sourceValue: 1_050.00, created: "2026-07-22 10:00:00" }

    result = described_class.new("2026-Q2").process([hmrc_transfer, stray])

    expect(result.matched.size).to eq(1)
    expect(result.unclaimed_transfers).to eq([stray])
  end

  it "does not report a transfer that was considered (even ambiguously) as unclaimed" do
    hmrc = create(:tax_remittance, :completed, currency: "GBP", period: "2026-Q2",
                                               target_amount_cents: 18_284_755, paid_at: Time.utc(2026, 7, 22),
                                               transfer_id: nil)
    duplicate = hmrc_transfer.merge(id: 900_003)

    result = described_class.new("2026-Q2").process([hmrc_transfer, duplicate])

    expect(result.ambiguous.first.remittance).to eq(hmrc)
    expect(result.unclaimed_transfers).to be_empty
  end
end
