# frozen_string_literal: true

require "spec_helper"

describe Onetime::ApplySourcelessCapitalDeductions do
  let(:seller) { create(:user) }
  let(:merchant_account) { create(:merchant_account, user: seller, currency: Currency::USD) }
  let(:blank_purchase) do
    create(:failed_purchase, link: create(:product, user: seller), merchant_account:).tap do |purchase|
      purchase.update_columns(stripe_transaction_id: nil, succeeded_at: nil)
    end
  end
  let(:credit) do
    create(:credit, user: seller, merchant_account:, financing_paydown_purchase: blank_purchase, crediting_user: nil,
                    stripe_loan_paydown_id: "cptxn_sourceless", amount_cents: -352, balance: nil)
  end
  let!(:transaction) do
    amount = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: -352, net_cents: -352)
    BalanceTransaction.create!(user: seller, merchant_account:, credit:, issued_amount: amount, holding_amount: amount, update_user_balance: false)
  end
  let!(:balance) do
    sale = create(:purchase, link: create(:product, user: seller), merchant_account:)
    amount = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: 5353, net_cents: 5353)
    BalanceTransaction.create!(user: seller, merchant_account:, purchase: sale, issued_amount: amount, holding_amount: amount).balance
  end
  let(:financing) do
    { id: "cptxn_sourceless", account: merchant_account.charge_processor_merchant_id, type: "payment", created_at: 1_787_000_000,
      details: { reason: "automatic_withholding", currency: "usd", total_amount: 352, linked_payment: "py_linked",
                 transaction: { charge: "py_linked" } } }
  end
  let(:source_transaction) { nil }
  let(:transfer_destination) { merchant_account.charge_processor_merchant_id }

  before do
    stub_const("#{described_class}::CREDIT_IDS", [credit.id])
    allow(Stripe).to receive(:raw_request)
      .with(:get, "/v1/capital/financing_transactions/cptxn_sourceless", {}, { stripe_account: merchant_account.charge_processor_merchant_id }) { double(http_body: financing.to_json) }
    allow(Stripe::Charge).to receive(:retrieve)
      .with("py_linked", { stripe_account: merchant_account.charge_processor_merchant_id })
      .and_return(double(source_transfer: "tr_source"))
    allow(Stripe::Transfer).to receive(:retrieve).with("tr_source")
      .and_return(double(source_transaction:, destination: transfer_destination))
  end

  def process(**options)
    described_class.new(**options).process.sole
  end

  it "defaults to a dry-run that reports the target balance without changing records" do
    expect(process).to include(status: :dry_run, credit_id: credit.id, balance_transaction_id: transaction.id, creates_balance_transaction: false,
                               unlinks_purchase_id: blank_purchase.id, balance_id: balance.id, before_cents: 5353, deduction_cents: -352,
                               after_cents: 5001)
    expect(credit.reload.financing_paydown_purchase_id).to eq(blank_purchase.id)
    expect(credit.balance_id).to be_nil
    expect(transaction.reload.balance_id).to be_nil
    expect(balance.reload.holding_amount_cents).to eq(5353)
  end

  it "unlinks the purchase and applies the existing transaction once" do
    expect { expect(process(dry_run: false)[:status]).to eq(:applied) }.not_to change { BalanceTransaction.count }

    credit.reload
    expect(credit.financing_paydown_purchase_id).to be_nil
    expect(credit.stripe_loan_paydown_reason).to eq(Credit::AUTOMATIC_CAPITAL_WITHHOLDING)
    expect(credit.stripe_loan_paydown_linked_payment_id).to eq("py_linked")
    expect(credit.stripe_loan_paydown_linked_transfer_id).to eq("tr_source")
    expect(credit.balance_id).to eq(balance.id)
    expect(transaction.reload.balance_id).to eq(balance.id)
    expect(balance.reload.holding_amount_cents).to eq(5001)
    expect(balance.amount_cents).to eq(5001)
    expect(balance.balance_transactions.sum(:holding_amount_net_cents)).to eq(5001)

    expect(process(dry_run: false)).to eq(status: :already_applied, credit_id: credit.id, balance_id: balance.id)
    expect(balance.reload.holding_amount_cents).to eq(5001)
  end

  it "creates the missing transaction in USD" do
    transaction.destroy!

    expect(process[:creates_balance_transaction]).to be(true)
    expect { process(dry_run: false) }.to change { BalanceTransaction.count }.by(1)
    created = credit.reload.balance_transaction
    expect([created.issued_amount_net_cents, created.holding_amount_net_cents, created.holding_amount_currency]).to eq([-352, -352, "usd"])
    expect(created.balance_id).to eq(balance.id)
    expect(balance.reload.holding_amount_cents).to eq(5001)
  end

  it "opens a balance dated to the Stripe deduction when none is unpaid" do
    balance.update_columns(state: "paid")

    expect(process).to include(status: :dry_run, balance_id: nil, new_balance_date: Time.zone.at(1_787_000_000).to_date,
                               before_cents: 0, deduction_cents: -352, after_cents: -352)
    process(dry_run: false)
    expect(credit.reload.balance.date).to eq(Time.zone.at(1_787_000_000).to_date)
    expect(credit.balance.holding_amount_cents).to eq(-352)
  end

  it "resumes a credit whose purchase link was already cleared" do
    allow_any_instance_of(Credit).to receive(:apply_financing_paydown!).and_raise("interrupted")
    expect(process(dry_run: false)).to include(status: :refused, error: "interrupted")
    expect(credit.reload.financing_paydown_purchase_id).to be_nil
    expect(credit.balance_id).to be_nil

    allow_any_instance_of(Credit).to receive(:apply_financing_paydown!).and_call_original
    expect(process(dry_run: false)).to include(status: :applied, balance_id: balance.id)
  end

  context "when the transaction was applied but the credit was never linked to its balance" do
    before do
      allow_any_instance_of(BalanceTransaction).to receive(:update_balance!).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs)
        raise "interrupted"
      end
      expect(process(dry_run: false)).to include(status: :refused, error: "interrupted")
      allow_any_instance_of(BalanceTransaction).to receive(:update_balance!).and_call_original
    end

    it "reports the link in the dry run without changing the balance" do
      expect(transaction.reload.balance_id).to eq(balance.id)
      expect(credit.reload.balance_id).to be_nil

      expect(process).to include(status: :dry_run, balance_id: balance.id, links_applied_transaction: true,
                                 before_cents: 5353, deduction_cents: -352, after_cents: 5001)
      expect(balance.reload.holding_amount_cents).to eq(5001)
    end

    it "links the credit without applying the deduction twice" do
      expect { expect(process(dry_run: false)).to include(status: :applied, balance_id: balance.id) }.not_to change { BalanceTransaction.count }

      expect(credit.reload.balance_id).to eq(balance.id)
      expect(balance.reload.holding_amount_cents).to eq(5001)
      expect(process(dry_run: false)).to eq(status: :already_applied, credit_id: credit.id, balance_id: balance.id)
      expect(balance.reload.holding_amount_cents).to eq(5001)
    end

    it "refuses a transaction applied to another seller's balance" do
      other_balance = create(:balance, user: create(:user), merchant_account: create(:merchant_account, currency: Currency::USD))
      transaction.update_columns(balance_id: other_balance.id)

      expect(process(dry_run: false)).to include(status: :refused, error: "Balance transaction does not match the credit")
      expect(credit.reload.balance_id).to be_nil
    end

    it "refuses a transaction applied to a balance of another merchant account of the seller" do
      other_account = create(:merchant_account, user: seller, currency: Currency::USD)
      transaction.update_columns(balance_id: create(:balance, user: seller, merchant_account: other_account).id)

      expect(process(dry_run: false)).to include(status: :refused, error: "Balance transaction does not match the credit")
      expect(credit.reload.balance_id).to be_nil
    end

    it "refuses a transaction applied to a non-USD balance" do
      balance.update_columns(holding_currency: Currency::CAD)

      expect(process(dry_run: false)).to include(status: :refused, error: "Balance transaction does not match the credit")
      expect(credit.reload.balance_id).to be_nil
    end
  end

  context "when the transfer names a charge" do
    let(:source_transaction) { "ch_real" }

    it "refuses without changing records" do
      expect(process(dry_run: false)).to include(status: :refused, error: "Source transfer names a charge")
      expect(credit.reload.financing_paydown_purchase_id).to eq(blank_purchase.id)
      expect(balance.reload.holding_amount_cents).to eq(5353)
    end
  end

  context "when the transfer goes to another account" do
    let(:transfer_destination) { "acct_other" }

    it "refuses" do
      expect(process(dry_run: false)).to include(status: :refused, error: "Source transfer goes to another account")
    end
  end

  it "refuses when Stripe's amount differs from the credit" do
    financing[:details][:total_amount] = 353

    expect(process(dry_run: false)).to include(status: :refused, error: "Stripe financing transaction does not match the credit")
    expect(credit.reload.balance_id).to be_nil
  end

  it "refuses a credit linked to a charged purchase" do
    blank_purchase.update_columns(stripe_transaction_id: "ch_real", succeeded_at: Time.current)

    expect(process(dry_run: false)).to include(status: :refused, error: "Credit is not linked to a never-charged purchase")
  end

  it "refuses a non-USD merchant account" do
    merchant_account.update_columns(currency: Currency::CAD)

    expect(process(dry_run: false)).to include(status: :refused, error: "Merchant account is not a USD Stripe account of the seller")
    expect(credit.reload.balance_id).to be_nil
  end

  it "refuses a transaction whose amount differs from the credit" do
    transaction.update_columns(holding_amount_net_cents: -351)

    expect(process(dry_run: false)).to include(status: :refused, error: "Balance transaction does not match the credit")
    expect(balance.reload.holding_amount_cents).to eq(5353)
  end

  it "refuses credits that are not listed" do
    expect { described_class.new(credit_ids: [credit.id + 1]) }.to raise_error(ArgumentError)
  end
end
