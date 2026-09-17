# frozen_string_literal: true

require "spec_helper"

describe Onetime::RepairCapitalDeduction do
  let(:seller) { create(:user) }
  let(:merchant_account) { create(:merchant_account, user: seller, currency: Currency::USD) }
  let(:purchase) { create(:purchase, link: create(:product, user: seller), merchant_account:) }
  let(:credit) do
    create(:credit, user: seller, merchant_account:, financing_paydown_purchase: purchase,
                    stripe_loan_paydown_id: "cptxn_repair", amount_cents: -780, balance: nil)
  end
  let(:transaction) do
    amount = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: -780, net_cents: -780)
    BalanceTransaction.create!(user: seller, merchant_account:, credit:, issued_amount: amount, holding_amount: amount, update_user_balance: false)
  end
  let(:balance) do
    amount = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: 5353, net_cents: 5353)
    BalanceTransaction.create!(user: seller, merchant_account:, purchase:, issued_amount: amount, holding_amount: amount).balance
  end
  let(:arguments) do
    { credit_id: credit.id, balance_transaction_id: transaction.id, balance_id: balance.id,
      stripe_loan_paydown_id: "cptxn_repair", expected_amount_cents: -780, expected_balance_cents: 5353 }
  end

  it "defaults to a dry-run without changing records" do
    result = described_class.new(**arguments).process

    expect(result).to include(status: :dry_run, before_cents: 5353, deduction_cents: -780, after_cents: 4573)
    expect(balance.reload.holding_amount_cents).to eq(5353)
    expect(credit.reload.balance_id).to be_nil
    expect(transaction.reload.balance_id).to be_nil
  end

  it "applies the existing deduction once and preserves the transaction sum" do
    service = described_class.new(**arguments, dry_run: false)
    expect { expect(service.process[:status]).to eq(:applied) }.not_to change { BalanceTransaction.count }
    expect(balance.reload.holding_amount_cents).to eq(4573)
    expect(balance.amount_cents).to eq(4573)
    expect(balance.balance_transactions.sum(:holding_amount_net_cents)).to eq(4573)
    expect(credit.reload.balance_id).to eq(balance.id)
    expect(transaction.reload.balance_id).to eq(balance.id)
    expect(service.process[:status]).to eq(:already_applied)
    expect(balance.reload.holding_amount_cents).to eq(4573)
  end

  it "rolls back all changes when linking the credit fails" do
    service = described_class.new(**arguments, dry_run: false)
    allow_any_instance_of(Credit).to receive(:update!).and_raise("interrupted")

    expect { service.process }.to raise_error("interrupted")
    expect(balance.reload.holding_amount_cents).to eq(5353)
    expect(transaction.reload.balance_id).to be_nil
    expect(credit.reload.balance_id).to be_nil
  end

  it "refuses a balance that changed after the dry-run" do
    service = described_class.new(**arguments, dry_run: false)
    balance.update!(amount_cents: 5354, holding_amount_cents: 5354)

    expect { service.process }.to raise_error("Target balance amount has changed")
    expect(transaction.reload.balance_id).to be_nil
  end

  %w[processing paid forfeited].each do |state|
    it "refuses a #{state} balance" do
      service = described_class.new(**arguments, dry_run: false)
      balance.update!(state:)

      expect { service.process }.to raise_error("Target balance is not unpaid")
      expect(transaction.reload.balance_id).to be_nil
    end
  end

  it "refuses an incorrect financing identifier" do
    expect { described_class.new(**arguments.merge(stripe_loan_paydown_id: "cptxn_other"), dry_run: false).process }
      .to raise_error("Credit does not match the expected Capital deduction")
    expect(transaction.reload.balance_id).to be_nil
  end

  it "refuses a transaction from another credit" do
    other = create(:credit, user: seller, merchant_account:)
    transaction.update_columns(credit_id: other.id)

    expect { described_class.new(**arguments, dry_run: false).process }
      .to raise_error("Balance transaction does not match the expected deduction")
    expect(balance.reload.holding_amount_cents).to eq(5353)
  end

  it "refuses a balance whose transaction sum does not match" do
    balance.balance_transactions.sole.update_columns(holding_amount_net_cents: 5352)

    expect { described_class.new(**arguments, dry_run: false).process }
      .to raise_error("Target balance does not match its transactions")
    expect(transaction.reload.balance_id).to be_nil
  end
end
