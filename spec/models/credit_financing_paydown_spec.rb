# frozen_string_literal: true

require "spec_helper"

describe Credit, "Capital deductions" do
  let(:seller) { create(:user) }
  let(:merchant_account) { create(:merchant_account, user: seller, currency: Currency::USD) }
  let(:purchase) { create(:purchase, link: create(:product, user: seller), merchant_account:) }
  let(:financing_id) { "cptxn_recover_capital" }
  let(:attributes) { { purchase:, merchant_account:, amount_cents: -780, stripe_loan_paydown_id: financing_id } }

  def apply_deduction
    described_class.create_for_financing_paydown!(**attributes)
  end

  def expect_one_deduction
    credits = seller.credits.where("json_data->'$.stripe_loan_paydown_id' = ?", financing_id)
    expect(credits.count).to eq(1)
    credit = credits.sole
    expect(BalanceTransaction.where(credit_id: credit.id).count).to eq(1)
    transaction = credit.balance_transaction
    expect(transaction.balance_id).to be_present
    expect(credit.balance_id).to eq(transaction.balance_id)
    expect(transaction.balance.holding_amount_cents).to eq(-780)
    expect(transaction.balance.amount_cents).to eq(-780)
  end

  it "applies one deduction across repeated deliveries" do
    2.times { apply_deduction }
    expect_one_deduction
  end

  it "recovers after the credit is saved but before its transaction is created" do
    allow(BalanceTransaction).to receive(:create!).and_raise("interrupted")
    expect { apply_deduction }.to raise_error("interrupted")
    expect(seller.credits.sole.balance_id).to be_nil
    allow(BalanceTransaction).to receive(:create!).and_call_original

    2.times { apply_deduction }
    expect_one_deduction
  end

  it "recovers after the transaction is saved but before the balance changes" do
    allow_any_instance_of(BalanceTransaction).to receive(:update_balance!).and_raise("interrupted")
    expect { apply_deduction }.to raise_error("interrupted")
    transaction_id = seller.credits.sole.balance_transaction.id
    allow_any_instance_of(BalanceTransaction).to receive(:update_balance!).and_call_original

    2.times { apply_deduction }
    expect_one_deduction
    expect(seller.credits.sole.balance_transaction.id).to eq(transaction_id)
  end

  it "repairs the credit reference without repeating an applied deduction" do
    allow_any_instance_of(Credit).to receive(:update!).and_raise("interrupted")
    expect { apply_deduction }.to raise_error("interrupted")
    expect(seller.credits.sole.balance_transaction.balance_id).to be_present
    expect(seller.credits.sole.balance_id).to be_nil
    allow_any_instance_of(Credit).to receive(:update!).and_call_original

    2.times { apply_deduction }
    expect_one_deduction
  end

  it "retries a withholding that arrives before the purchase succeeds" do
    purchase.update_columns(succeeded_at: nil, purchase_state: "in_progress")
    expect { apply_deduction }.to raise_error("Capital purchase has not succeeded yet")
    expect(seller.credits.sole.balance_transaction).to be_nil
    purchase.update_columns(succeeded_at: Time.current, purchase_state: "successful")

    2.times { apply_deduction }
    expect_one_deduction
  end

  it "does not deduct from a paid historical balance during recovery" do
    old_balance = create(:balance, user: seller, merchant_account:, date: purchase.succeeded_at.to_date, amount_cents: 1000, holding_amount_cents: 1000, state: "paid")
    unpaid_balance = create(:balance, user: seller, merchant_account:, date: Date.tomorrow, amount_cents: 0, holding_amount_cents: 0)

    credit = apply_deduction

    expect(credit.balance).to eq(unpaid_balance)
    expect(old_balance.reload.holding_amount_cents).to eq(1000)
    expect_one_deduction
  end

  it "rejects a duplicate financing identifier with a different amount" do
    apply_deduction
    expect { described_class.create_for_financing_paydown!(**attributes.merge(amount_cents: -781)) }.to raise_error(ArgumentError)
    expect_one_deduction
  end
  it "recovers an existing orphan through the Stripe event handler without another Stripe lookup" do
    credit = create(:credit, user: seller, merchant_account:, financing_paydown_purchase: purchase,
                             stripe_loan_paydown_id: financing_id, amount_cents: -780, balance: nil)
    amount = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: -780, net_cents: -780)
    BalanceTransaction.create!(user: seller, merchant_account:, credit:, issued_amount: amount, holding_amount: amount, update_user_balance: false)
    expect(Stripe::Charge).not_to receive(:retrieve)
    expect(Stripe::Transfer).not_to receive(:retrieve)
    event = { "type" => "capital.financing_transaction.created", "data" => { "object" => {
      "type" => "payment", "id" => financing_id, "account" => merchant_account.charge_processor_merchant_id,
      "details" => { "currency" => "usd", "total_amount" => 780, "reason" => "automatic_withholding" }
    } } }

    2.times { StripeChargeProcessor.handle_stripe_capital_loan_event(event) }
    expect_one_deduction
  end

  it "does not apply a stale transaction again after another attempt links it" do
    credit = apply_deduction
    transaction = credit.balance_transaction
    transaction.update_columns(balance_id: nil)
    stale = BalanceTransaction.find(transaction.id)
    transaction.update_columns(balance_id: credit.balance_id)

    stale.update_balance!

    expect_one_deduction
  end
  it "rechecks application after balance selection races with another attempt" do
    credit = create(:credit, user: seller, merchant_account:, financing_paydown_purchase: purchase,
                             stripe_loan_paydown_id: financing_id, amount_cents: -780, balance: nil)
    amount = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: -780, net_cents: -780)
    transaction = BalanceTransaction.create!(user: seller, merchant_account:, credit:, issued_amount: amount, holding_amount: amount, update_user_balance: false)
    competing_transaction = BalanceTransaction.find(transaction.id)
    allow(transaction).to receive(:find_or_create_balance).and_wrap_original do |method|
      selected_balance = method.call
      competing_transaction.update_balance!
      selected_balance
    end

    transaction.update_balance!
    credit.apply_financing_paydown!

    expect_one_deduction
  end
  it "keeps duplicate manual repayments unchanged when the event uses a different currency" do
    merchant_account.update!(currency: Currency::GBP)
    credit = create(:credit, user: seller, merchant_account:, stripe_loan_paydown_id: financing_id, amount_cents: -1000)
    event = { "type" => "capital.financing_transaction.created", "data" => { "object" => {
      "type" => "payment", "id" => financing_id, "account" => merchant_account.charge_processor_merchant_id,
      "user_facing_description" => "Forced debit from Stripe Payments",
      "details" => { "currency" => "gbp", "total_amount" => 780, "reason" => "collection" }
    } } }

    expect { StripeChargeProcessor.handle_stripe_capital_loan_event(event) }.not_to change { Credit.count }
    expect(credit.reload.amount_cents).to eq(-1000)
  end
end
