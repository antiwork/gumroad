# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillAprilTaxRemittances do
  it "creates all seven April 2026 remittances as completed Wise payments with their GL dates" do
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
    expect(hmrc.paid_at).to eq(Time.utc(2026, 4, 28))
    expect(hmrc.target_amount_cents).to be_nil

    oss = TaxRemittance.find_by!(jurisdiction: "EU_OSS", period: "2026-Q1")
    expect(oss.usd_amount_cents).to eq(70_308_965)
    expect(oss.paid_at).to eq(Time.utc(2026, 4, 17))

    ato = TaxRemittance.find_by!(jurisdiction: "AU", period: "2026-Q1")
    expect(ato.paid_at).to eq(Time.utc(2026, 4, 13))

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

  it "raises when an existing row conflicts with the backfill data" do
    create(:tax_remittance, :completed, usd_amount_cents: 1) # wrong amount — not the real April payment

    expect { described_class.new.process }.to raise_error(/HMRC 2026-Q1 row conflicts/)
  end

  it "raises when an existing row has a different payment date" do
    create(:tax_remittance, :completed, usd_amount_cents: 25_333_498, paid_at: Time.utc(2026, 4, 15))

    expect { described_class.new.process }.to raise_error(/paid_at/)
  end

  it "does not mistake a later attempt for the historical first payment" do
    # A failed attempt 2 exists for HMRC's filing (attempt 1 slot open). The
    # backfill must still create the historical attempt-1 row rather than
    # treating the unrelated later attempt as already-backfilled.
    later_attempt = create(:tax_remittance, :failed, attempt: 2)

    service = described_class.new.process

    expect(service.created.size).to eq(7)
    expect(service.skipped).to be_empty

    hmrc_first = TaxRemittance.find_by!(authority: "HMRC", period: "2026-Q1", attempt: 1)
    expect(hmrc_first.status).to eq("completed")
    expect(hmrc_first.usd_amount_cents).to eq(25_333_498)
    expect(later_attempt.reload.attempt).to eq(2)
  end

  it "raises a descriptive error when a later attempt is live and attempt 1 is missing" do
    # A draft attempt 2 exists for HMRC's filing with no attempt-1 row. The
    # backfilled row is `completed` (live), so inserting it would put two live
    # attempts on one filing — the backfill must fail with an actionable
    # message instead of an opaque validation error, and must not write the
    # HMRC row.
    create(:tax_remittance, status: "draft", paid_at: nil, attempt: 2)

    expect { described_class.new.process }.to raise_error(/HMRC 2026-Q1 has a live attempt 2 \(status draft\)/)
    expect(TaxRemittance.find_by(authority: "HMRC", period: "2026-Q1", attempt: 1)).to be_nil
  end
end
