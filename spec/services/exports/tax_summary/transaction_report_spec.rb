# frozen_string_literal: true

require "spec_helper"

describe Exports::TaxSummary::TransactionReport do
  let(:seller) { create(:user) }
  let(:stripe_account_id) { "acct_1234567890" }
  let(:year) { 2025 }

  let!(:product) { create(:product, user: seller, price_cents: 1000) }
  let!(:purchase) do
    create(:purchase, link: product, price_cents: 1000, gumroad_tax_cents: 80,
                      stripe_transaction_id: "ch_matched")
  end

  def stripe_transaction(source:, amount:, created:, available_on:)
    Stripe::BalanceTransaction.construct_from(
      id: "txn_#{source}",
      type: "charge",
      source:,
      amount:,
      created: created.to_i,
      available_on: available_on.to_i
    )
  end

  it "writes one row per balance transaction, matched to the Gumroad sale, with a total row" do
    transactions = [
      stripe_transaction(source: "ch_matched", amount: 1080, created: Time.utc(2025, 3, 10), available_on: Time.utc(2025, 3, 12)),
      stripe_transaction(source: "ch_orphan", amount: 500, created: Time.utc(2024, 12, 31), available_on: Time.utc(2025, 1, 2))
    ]
    list = double("list")
    allow(list).to receive(:auto_paging_each) { |&block| transactions.each(&block) }
    expect(Stripe::BalanceTransaction).to receive(:list).with(
      { type: "charge", available_on: { gte: Time.utc(2025).to_i, lt: Time.utc(2026).to_i }, limit: 100 },
      { stripe_account: stripe_account_id }
    ).and_return(list)

    tempfile = described_class.new(user: seller, year:, stripe_account_id:).perform
    rows = CSV.parse(tempfile.read)

    expect(rows[0]).to eq(described_class::HEADERS)

    # Rows are sorted by the funds-available date, so the orphan charge from
    # January comes before the matched charge from March.
    expect(rows[1]).to eq(["2024-12-31", "2025-01-02", "ch_orphan", nil, nil, nil, "5.00"])
    expect(rows[2]).to eq(["2025-03-10", "2025-03-12", "ch_matched", purchase.external_id, "10.00", "0.80", "10.80"])
    expect(rows[3]).to eq(["Total", nil, nil, nil, nil, nil, "15.80"])
  end

  it "leaves the Gumroad columns blank for a charge whose purchase failed" do
    # A failed purchase can still carry the charge ID of a captured payment.
    # The report must not present it as a matched sale — a blank row is how
    # orphan captures inflating the form's gross get surfaced.
    create(:failed_purchase, link: product, price_cents: 1000, gumroad_tax_cents: 80,
                             stripe_transaction_id: "ch_failed")

    transactions = [
      stripe_transaction(source: "ch_failed", amount: 1080, created: Time.utc(2025, 5, 1), available_on: Time.utc(2025, 5, 3))
    ]
    list = double("list")
    allow(list).to receive(:auto_paging_each) { |&block| transactions.each(&block) }
    allow(Stripe::BalanceTransaction).to receive(:list).and_return(list)

    tempfile = described_class.new(user: seller, year:, stripe_account_id:).perform
    rows = CSV.parse(tempfile.read)

    expect(rows[1]).to eq(["2025-05-01", "2025-05-03", "ch_failed", nil, nil, nil, "10.80"])
    expect(rows[2]).to eq(["Total", nil, nil, nil, nil, nil, "10.80"])
  end
end
