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

  def create_credit(amount_cents:, stripe_id:, total_amount: -amount_cents)
    purchase = create(:failed_purchase, link: create(:product, user: seller), merchant_account:).tap do |record|
      record.update_columns(stripe_transaction_id: nil, succeeded_at: nil)
    end
    created = create(:credit, user: seller, merchant_account:, financing_paydown_purchase: purchase, crediting_user: nil,
                              stripe_loan_paydown_id: stripe_id, amount_cents:, balance: nil)
    amount = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: amount_cents, net_cents: amount_cents)
    BalanceTransaction.create!(user: seller, merchant_account:, credit: created, issued_amount: amount, holding_amount: amount, update_user_balance: false)
    stripe_financing = financing.deep_merge(id: stripe_id, details: { total_amount: })
    allow(Stripe).to receive(:raw_request)
      .with(:get, "/v1/capital/financing_transactions/#{stripe_id}", {}, { stripe_account: merchant_account.charge_processor_merchant_id }) { double(http_body: stripe_financing.to_json) }
    stub_const("#{described_class}::CREDIT_IDS", described_class::CREDIT_IDS + [created.id])
    created
  end

  # What an interrupted run leaves: purchase link cleared, Stripe fields written, nothing applied.
  def clear_link(target, **overrides)
    target.update!(financing_paydown_purchase: nil, stripe_loan_paydown_reason: Credit::AUTOMATIC_CAPITAL_WITHHOLDING,
                   stripe_loan_paydown_currency: Currency::USD, stripe_loan_paydown_deducted_at: 1_787_000_000,
                   stripe_loan_paydown_linked_payment_id: "py_linked", stripe_loan_paydown_linked_transfer_id: "tr_source", **overrides)
  end

  it "defaults to a dry-run that reports the target balance without changing records" do
    expect(process).to include(status: :dry_run, credit_id: credit.id, balance_transaction_id: transaction.id, creates_balance_transaction: false,
                               unlinks_purchase_id: blank_purchase.id, balance_id: balance.id, balance_state: "unpaid", before_cents: 5353,
                               deduction_cents: -352, after_cents: 5001, ledger_after_cents: 5001, ends_negative: false)
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

    %w[paid processing].each do |state|
      it "links a transaction applied to a #{state} balance and reports that state" do
        balance.update_columns(state:)

        expect(process).to include(status: :dry_run, balance_id: balance.id, balance_state: state, links_applied_transaction: true,
                                   before_cents: 5353, after_cents: 5001, ledger_after_cents: 0, ends_negative: false)
        expect(process(dry_run: false)).to include(status: :applied, balance_id: balance.id)
        expect(credit.reload.balance_id).to eq(balance.id)
        expect(balance.reload.holding_amount_cents).to eq(5001)
        expect(balance.state).to eq(state)
      end
    end

    it "never skips an already applied transaction, even when the ledger is negative" do
      balance.update_columns(holding_amount_cents: -10, amount_cents: -10)

      expect(process(skip_negative: true)).to include(status: :dry_run, ends_negative: true, links_applied_transaction: true)
      expect(process(dry_run: false, skip_negative: true)).to include(status: :applied)
      expect(credit.reload.balance_id).to eq(balance.id)
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

  it "resumes an unlinked credit that has no transaction" do
    transaction.destroy!
    clear_link(credit)

    expect(process).to include(status: :dry_run, creates_balance_transaction: true, unlinks_purchase_id: nil, balance_id: balance.id,
                               before_cents: 5353, after_cents: 5001)
    expect { expect(process(dry_run: false)).to include(status: :applied, balance_id: balance.id) }.to change { BalanceTransaction.count }.by(1)
    expect(balance.reload.holding_amount_cents).to eq(5001)
  end

  context "when the credit stores a Stripe field that differs from Stripe" do
    it "refuses a cleared credit with another deduction time" do
      clear_link(credit, stripe_loan_paydown_deducted_at: 1_787_000_001)

      expect(process(dry_run: false)).to include(status: :refused, error: "Stored stripe_loan_paydown_deducted_at does not match Stripe")
      expect(credit.reload.balance_id).to be_nil
      expect(credit.stripe_loan_paydown_deducted_at).to eq(1_787_000_001)
      expect(balance.reload.holding_amount_cents).to eq(5353)
    end

    it "refuses a cleared credit that lacks a Stripe field" do
      clear_link(credit, stripe_loan_paydown_linked_transfer_id: nil)

      expect(process(dry_run: false)).to include(status: :refused, error: "Stored stripe_loan_paydown_linked_transfer_id does not match Stripe")
      expect(balance.reload.holding_amount_cents).to eq(5353)
    end

    it "refuses a linked credit with another stored payment ID before overwriting it" do
      credit.update!(stripe_loan_paydown_linked_payment_id: "py_other")

      expect(process(dry_run: false)).to include(status: :refused, error: "Stored stripe_loan_paydown_linked_payment_id does not match Stripe")
      expect(credit.reload.financing_paydown_purchase_id).to eq(blank_purchase.id)
      expect(credit.stripe_loan_paydown_linked_payment_id).to eq("py_other")
      expect(balance.reload.holding_amount_cents).to eq(5353)
    end

    it "accepts a linked credit whose stored IDs equal Stripe's" do
      credit.update!(stripe_loan_paydown_linked_payment_id: "py_linked", stripe_loan_paydown_linked_transfer_id: "tr_source")

      expect(process(dry_run: false)).to include(status: :applied)
    end
  end

  context "with several credits of one seller" do
    let!(:second) { create_credit(amount_cents: -100, stripe_id: "cptxn_second") }

    def statuses(**options)
      described_class.new(credit_ids: [credit.id, second.id], **options).process
    end

    it "reports amounts that accumulate on the balance in a dry run" do
      first, last = statuses
      expect(first).to include(status: :dry_run, before_cents: 5353, after_cents: 5001, ledger_after_cents: 5001)
      expect(last).to include(status: :dry_run, before_cents: 5001, deduction_cents: -100, after_cents: 4901, ledger_after_cents: 4901, ends_negative: false)
      expect(balance.reload.holding_amount_cents).to eq(5353)
    end

    it "matches the dry run with the balance a live run leaves" do
      expect(statuses(dry_run: false).map { _1[:status] }).to eq(%i[applied applied])
      expect(balance.reload.holding_amount_cents).to eq(4901)
    end

    it "flags a ledger of exactly zero as holding payouts without calling it negative" do
      balance.update_columns(holding_amount_cents: 452, amount_cents: 452)

      expect(statuses(skip_negative: true).map { _1.values_at(:status, :ledger_after_cents, :ends_negative, :payout_held) })
        .to eq([[:dry_run, 100, false, false], [:dry_run, 0, false, true]])
    end

    it "accounts for an earlier credit when it previews an applied transaction on the same balance" do
      allow_any_instance_of(BalanceTransaction).to receive(:update_balance!).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs)
        raise "interrupted"
      end
      described_class.new(credit_ids: [second.id], dry_run: false).process
      allow_any_instance_of(BalanceTransaction).to receive(:update_balance!).and_call_original
      expect(second.reload.balance_transaction.balance_id).to eq(balance.id)
      expect(balance.reload.holding_amount_cents).to eq(5253)

      first, applied = described_class.new(credit_ids: [credit.id, second.id]).process
      expect(first).to include(before_cents: 5253, after_cents: 4901)
      expect(applied).to include(links_applied_transaction: true, before_cents: 5001, after_cents: 4901, ledger_after_cents: 4901)
    end

    it "accumulates on a balance that does not exist yet" do
      balance.update_columns(state: "paid")

      first, last = statuses
      expect(first).to include(balance_id: nil, before_cents: 0, after_cents: -352, ledger_after_cents: -352, ends_negative: true)
      expect(last).to include(balance_id: nil, before_cents: -352, after_cents: -452, ledger_after_cents: -452)
    end

    it "leaves another credit applied when one is refused" do
      refused = create_credit(amount_cents: -50, stripe_id: "cptxn_refused", total_amount: 51)

      results = described_class.new(credit_ids: [credit.id, refused.id, second.id], dry_run: false).process
      expect(results.map { _1[:status] }).to eq(%i[applied refused applied])
      expect(results.second[:error]).to eq("Stripe financing transaction does not match the credit")
      expect(balance.reload.holding_amount_cents).to eq(4901)
      expect(refused.reload.balance_id).to be_nil
      expect(refused.financing_paydown_purchase_id).to be_present
    end

    it "flags a negative account group even when the seller's total stays positive" do
      balance.update_columns(merchant_account_id: create(:merchant_account, user: seller, currency: Currency::USD).id)

      first = statuses.first
      expect(first).to include(status: :dry_run, balance_id: nil, before_cents: 0, after_cents: -352, ledger_after_cents: 5001,
                               ends_negative: true, payout_held: true)
    end

    it "skips a credit that would leave its own account group negative" do
      balance.update_columns(merchant_account_id: create(:merchant_account, user: seller, currency: Currency::USD).id)

      expect(statuses(skip_negative: true).map { _1[:status] }).to eq(%i[skipped skipped])
      expect(statuses(dry_run: false, skip_negative: true).map { _1[:status] }).to eq(%i[skipped skipped])
      expect(credit.reload.balance_id).to be_nil
    end

    it "does not skip a credit because another account of the seller is already negative" do
      other = create(:merchant_account, user: seller, currency: Currency::USD)
      balance.update_columns(merchant_account_id: other.id, amount_cents: -10, holding_amount_cents: -10)
      Balance.create!(user: seller, merchant_account:, date: Date.current - 1, currency: Currency::USD, holding_currency: Currency::USD,
                      amount_cents: 900, holding_amount_cents: 900)

      expect(statuses(skip_negative: true).first).to include(status: :dry_run, ends_negative: false, payout_held: true)
    end

    it "counts Gumroad-held funds toward the payout account's group, as Payouts does" do
      balance.update_columns(amount_cents: 0, holding_amount_cents: 0)
      create(:balance, user: seller, date: Date.current - 1, amount_cents: 5000)

      expect(statuses(skip_negative: true).first).to include(status: :dry_run, ends_negative: false, payout_held: false, ledger_after_cents: 4648)
      expect(statuses(dry_run: false, skip_negative: true).map { _1[:status] }).to eq(%i[applied applied])
    end

    it "still skips when Gumroad-held funds do not cover the payout account's group" do
      balance.update_columns(amount_cents: 0, holding_amount_cents: 0)
      create(:balance, user: seller, date: Date.current - 1, amount_cents: 100)

      expect(statuses(skip_negative: true).first).to include(status: :skipped, ledger_after_cents: -252)
      expect(statuses.first).to include(status: :dry_run, ends_negative: true, payout_held: true)
    end

    it "names the first credit's date for every row that shares a balance to be opened" do
      balance.update_columns(state: "paid")
      financing_second = financing.deep_merge(id: "cptxn_second", created_at: 1_787_200_000, details: { total_amount: 100 })
      allow(Stripe).to receive(:raw_request)
        .with(:get, "/v1/capital/financing_transactions/cptxn_second", {}, { stripe_account: merchant_account.charge_processor_merchant_id }) { double(http_body: financing_second.to_json) }

      first, last = statuses
      expect(first[:new_balance_date]).to eq(Time.zone.at(1_787_000_000).to_date)
      expect(last[:new_balance_date]).to eq(first[:new_balance_date])
      expect(last).to include(before_cents: -352, after_cents: -452)
    end

    it "holds the seller lock while it applies a credit under skip_negative, and only then" do
      locked = []
      allow_any_instance_of(User).to receive(:with_lock).and_wrap_original do |original, *args, &block|
        locked << true
        original.call(*args, &block)
      end

      statuses(dry_run: false)
      expect(locked).to be_empty
      third = create_credit(amount_cents: -10, stripe_id: "cptxn_third")
      expect(described_class.new(credit_ids: [third.id], dry_run: false, skip_negative: true).process.sole).to include(status: :applied)
      expect(locked.size).to eq(1)
    end

    context "when a deduction would end the unpaid ledger below zero" do
      let!(:large) { create_credit(amount_cents: -6000, stripe_id: "cptxn_large") }

      def outcomes(**options)
        described_class.new(credit_ids: [credit.id, large.id, second.id], **options).process
      end

      it "applies it by default and reports the negative ledger in the dry run" do
        expect(outcomes.map { _1.values_at(:status, :ledger_after_cents, :ends_negative) })
          .to eq([[:dry_run, 5001, false], [:dry_run, -999, true], [:dry_run, -1099, true]])

        expect(outcomes(dry_run: false).map { _1[:status] }).to eq(%i[applied applied applied])
        expect(balance.reload.holding_amount_cents).to eq(-1099)
      end

      it "skips it when asked, and later credits do not count it" do
        results = outcomes(skip_negative: true)
        expect(results.map { _1[:status] }).to eq(%i[dry_run skipped dry_run])
        expect(results.second).to include(credit_id: large.id, reason: "Ledger would go negative", ledger_after_cents: -999)
        expect(results.third).to include(before_cents: 5001, after_cents: 4901, ledger_after_cents: 4901)

        expect(outcomes(dry_run: false, skip_negative: true).map { _1[:status] }).to eq(%i[applied skipped applied])
        expect(balance.reload.holding_amount_cents).to eq(4901)
        expect(large.reload.balance_id).to be_nil
        expect(large.financing_paydown_purchase_id).to be_present
      end
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

  it "refuses a batch that repeats a credit, which a dry run would count twice" do
    expect { described_class.new(credit_ids: [credit.id, credit.id]) }.to raise_error(ArgumentError, "Credit IDs must be unique")
  end

  it "reports the same numbers when the same instance processes again" do
    task = described_class.new
    expect(task.process).to eq(task.process)
  end

  it "refuses credits that are not listed" do
    expect { described_class.new(credit_ids: [credit.id + 1]) }.to raise_error(ArgumentError)
  end
end
