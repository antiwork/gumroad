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

  # A "payment" balance transaction is how money arrives on a Gumroad-managed
  # Stripe account: the buyer was charged on Gumroad's platform account and
  # the creator's share was transferred over. The source is a py_ charge on
  # the creator's account, and the path back to the platform-side charge ID
  # (which is what purchases store) is source.source_transfer.source_transaction.
  def stripe_payment_transaction(platform_charge_id:, amount:, created:, available_on:)
    Stripe::BalanceTransaction.construct_from(
      id: "txn_py_#{platform_charge_id}",
      type: "payment",
      source: {
        id: "py_#{platform_charge_id}",
        object: "charge",
        source_transfer: {
          id: "tr_#{platform_charge_id}",
          object: "transfer",
          source_transaction: platform_charge_id
        }
      },
      amount:,
      created: created.to_i,
      available_on: available_on.to_i
    )
  end

  def stub_transaction_list(charge_transactions: [], payment_transactions: [])
    { "charge" => charge_transactions, "payment" => payment_transactions }.each do |type, transactions|
      list = double("list_#{type}")
      allow(list).to receive(:auto_paging_each) { |&block| transactions.each(&block) }
      expect(Stripe::BalanceTransaction).to receive(:list).with(
        {
          type:,
          available_on: { gte: Time.utc(year).to_i, lt: Time.utc(year + 1).to_i },
          limit: 100,
          expand: ["data.source.source_transfer"]
        },
        { stripe_account: stripe_account_id }
      ).and_return(list)
    end
  end

  it "writes one row per balance transaction, matched to the Gumroad sale, with a total row" do
    stub_transaction_list(charge_transactions: [
                            stripe_transaction(source: "ch_matched", amount: 1080, created: Time.utc(2025, 3, 10), available_on: Time.utc(2025, 3, 12)),
                            stripe_transaction(source: "ch_orphan", amount: 500, created: Time.utc(2024, 12, 31), available_on: Time.utc(2025, 1, 2))
                          ])

    tempfile = described_class.new(user: seller, year:, stripe_account_id:).perform
    rows = CSV.parse(tempfile.read)

    expect(rows[0]).to eq(described_class::HEADERS)

    # Rows are sorted by the funds-available date, so the orphan charge from
    # January comes before the matched charge from March.
    expect(rows[1]).to eq(["2024-12-31", "2025-01-02", "ch_orphan", nil, nil, nil, "5.00"])
    expect(rows[2]).to eq(["2025-03-10", "2025-03-12", "ch_matched", purchase.external_id, "10.00", "0.80", "10.80"])
    expect(rows[3]).to eq(["Total", nil, nil, nil, nil, nil, "15.80"])
  end

  it "matches payment-type transactions back to the platform-side charge stored on the purchase" do
    # Gumroad-managed accounts (the overwhelming majority of 1099-K sellers)
    # receive their money as transferred payments, not direct charges. The
    # report must follow the transfer back to the platform charge ID or every
    # row would show up as an unmatched orphan.
    stub_transaction_list(payment_transactions: [
                            stripe_payment_transaction(platform_charge_id: "ch_matched", amount: 790, created: Time.utc(2025, 6, 1), available_on: Time.utc(2025, 6, 3))
                          ])

    tempfile = described_class.new(user: seller, year:, stripe_account_id:).perform
    rows = CSV.parse(tempfile.read)

    expect(rows[1]).to eq(["2025-06-01", "2025-06-03", "ch_matched", purchase.external_id, "10.00", "0.80", "7.90"])
    expect(rows[2]).to eq(["Total", nil, nil, nil, nil, nil, "7.90"])
  end

  it "combines every purchase sharing a charge into one row" do
    # A multi-product cart checkout creates a single Stripe charge covering
    # several purchases, each carrying the same charge ID. The row must show
    # the combined totals or the numbers would look like a discrepancy.
    second_product = create(:product, user: seller, price_cents: 500)
    second_purchase = create(:purchase, link: second_product, price_cents: 500, gumroad_tax_cents: 40,
                                        stripe_transaction_id: "ch_matched")

    stub_transaction_list(charge_transactions: [
                            stripe_transaction(source: "ch_matched", amount: 1620, created: Time.utc(2025, 3, 10), available_on: Time.utc(2025, 3, 12))
                          ])

    tempfile = described_class.new(user: seller, year:, stripe_account_id:).perform
    rows = CSV.parse(tempfile.read)

    expect(rows[1]).to eq([
                            "2025-03-10", "2025-03-12", "ch_matched",
                            "#{purchase.external_id}; #{second_purchase.external_id}",
                            "15.00", "1.20", "16.20"
                          ])
    expect(rows[2]).to eq(["Total", nil, nil, nil, nil, nil, "16.20"])
  end

  it "leaves the Gumroad columns blank for a charge whose purchase failed" do
    # A failed purchase can still carry the charge ID of a captured payment.
    # The report must not present it as a matched sale — a blank row is how
    # orphan captures inflating the form's total get surfaced.
    create(:failed_purchase, link: product, price_cents: 1000, gumroad_tax_cents: 80,
                             stripe_transaction_id: "ch_failed")

    stub_transaction_list(charge_transactions: [
                            stripe_transaction(source: "ch_failed", amount: 1080, created: Time.utc(2025, 5, 1), available_on: Time.utc(2025, 5, 3))
                          ])

    tempfile = described_class.new(user: seller, year:, stripe_account_id:).perform
    rows = CSV.parse(tempfile.read)

    expect(rows[1]).to eq(["2025-05-01", "2025-05-03", "ch_failed", nil, nil, nil, "10.80"])
    expect(rows[2]).to eq(["Total", nil, nil, nil, nil, nil, "10.80"])
  end
end
