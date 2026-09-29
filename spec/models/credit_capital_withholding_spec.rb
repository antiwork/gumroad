# frozen_string_literal: true

require "spec_helper"

describe Credit, "Capital withholdings without a provable sale" do
  let(:seller) { create(:user) }
  let(:merchant_account) { create(:merchant_account, user: seller, currency: Currency::USD) }
  let(:product) { create(:product, user: seller) }
  let(:financing_id) { "cptxn_account_withholding" }
  let(:now) { Time.utc(2026, 9, 20, 15) }
  let(:deducted_at) { Time.utc(2026, 9, 10, 12) }

  around { |example| travel_to(now) { example.run } }

  def capital_event(amount: 780, currency: merchant_account.currency, charge: "py_linked", linked_payment: "py_linked", created_at: deducted_at.to_i)
    details = { "currency" => currency, "total_amount" => amount, "reason" => "automatic_withholding" }
    details["transaction"] = { "charge" => charge } unless charge.nil?
    details["linked_payment"] = linked_payment unless linked_payment.nil?
    { "type" => "capital.financing_transaction.created", "created" => created_at.to_i + 5, "data" => { "object" => {
      "type" => "payment", "id" => financing_id, "account" => merchant_account.charge_processor_merchant_id,
      "created_at" => created_at, "details" => details
    } } }
  end

  def deliver(event = capital_event)
    StripeChargeProcessor.handle_stripe_capital_loan_event(event)
  end

  def stub_linked_transfer(source_transaction, transfer_id: "tr_linked")
    allow(Stripe::Charge).to receive(:retrieve)
      .with("py_linked", { stripe_account: merchant_account.charge_processor_merchant_id })
      .and_return(double(source_transfer: transfer_id))
    allow(Stripe::Transfer).to receive(:retrieve).with(transfer_id).and_return(double(source_transaction:))
  end

  def capital_credits
    seller.credits.where("json_data->'$.stripe_loan_paydown_id' = ?", financing_id)
  end

  def expect_one_applied_deduction(holding_cents: -780, issued_cents: holding_cents)
    credit = capital_credits.sole
    expect(BalanceTransaction.where(credit_id: credit.id).count).to eq(1)
    transaction = credit.balance_transaction
    expect(transaction.balance_id).to be_present
    expect(credit.balance_id).to eq(transaction.balance_id)
    expect([transaction.issued_amount_currency, transaction.issued_amount_gross_cents, transaction.issued_amount_net_cents])
      .to eq([Currency::USD, issued_cents, issued_cents])
    expect([transaction.holding_amount_currency, transaction.holding_amount_gross_cents, transaction.holding_amount_net_cents])
      .to eq([merchant_account.currency, holding_cents, holding_cents])
    credit
  end

  # The shape the wrong links pointed at: a failed sale whose charge id was never stored.
  def failed_purchase_without_charge(charge_id = nil)
    create(:failed_purchase, link: product).tap { _1.update_columns(stripe_transaction_id: charge_id, succeeded_at: nil) }
  end

  def saved_account_withholding(**attributes)
    Credit.create!(user: seller, merchant_account:, amount_cents: -780, stripe_loan_paydown_id: financing_id,
                   stripe_loan_paydown_reason: "automatic_withholding", stripe_loan_paydown_deducted_at: deducted_at.to_i,
                   stripe_loan_paydown_currency: Currency::USD, stripe_loan_paydown_usd_rate: "1.0", stripe_loan_paydown_usd_cents: -780,
                   **attributes)
  end

  describe "resolving the withheld sale" do
    it "does not link a nil source to a failed purchase with no charge id" do
      failed_purchase = failed_purchase_without_charge
      stub_linked_transfer(nil)

      deliver

      credit = expect_one_applied_deduction
      expect(credit.financing_paydown_purchase_id).to be_nil
      expect(credit.stripe_loan_paydown_linked_payment_id).to eq("py_linked")
      expect(credit.stripe_loan_paydown_linked_transfer_id).to eq("tr_linked")
      expect(Credit.where(financing_paydown_purchase_id: failed_purchase.id)).to be_empty
    end

    it "does not link a blank source to a purchase with a blank charge id" do
      blank_purchase = failed_purchase_without_charge("")
      stub_linked_transfer("")

      deliver

      expect(expect_one_applied_deduction.financing_paydown_purchase_id).to be_nil
      expect(Credit.where(financing_paydown_purchase_id: blank_purchase.id)).to be_empty
    end

    it "keeps the sale link when the transfer names one of the seller's sales" do
      purchase = create(:purchase, link: product, stripe_transaction_id: "ch_withheld_sale")
      stub_linked_transfer("ch_withheld_sale")

      deliver

      credit = expect_one_applied_deduction
      expect(credit.financing_paydown_purchase).to eq(purchase)
      expect(credit.stripe_loan_paydown_reason).to eq("automatic_withholding")
      expect(credit.stripe_loan_paydown_deducted_at).to eq(deducted_at.to_i)
    end

    it "refuses a source that names no sale of this seller" do
      create(:purchase, link: create(:product), stripe_transaction_id: "ch_other_seller")
      stub_linked_transfer("ch_other_seller")

      expect { deliver }.to raise_error(/has no sale for seller/)
      expect(capital_credits).to be_empty
    end

    it "records the withholding without Stripe lookups when the event names no payment" do
      expect(Stripe::Charge).not_to receive(:retrieve)
      expect(Stripe::Transfer).not_to receive(:retrieve)

      deliver(capital_event(charge: nil, linked_payment: nil))

      expect(expect_one_applied_deduction.stripe_loan_paydown_linked_payment_id).to be_nil
    end

    it "records the withholding when the linked payment did not come from a transfer" do
      allow(Stripe::Charge).to receive(:retrieve).and_return(double(source_transfer: nil))
      expect(Stripe::Transfer).not_to receive(:retrieve)

      deliver

      expect(expect_one_applied_deduction.financing_paydown_purchase_id).to be_nil
    end

    describe "a charge shared by several of the seller's sales" do
      let!(:first_sale) { create(:purchase, link: product, stripe_transaction_id: "ch_cart", succeeded_at: now - 2.hours) }
      let!(:second_sale) { create(:purchase, link: create(:product, user: seller), stripe_transaction_id: "ch_cart", succeeded_at: now - 1.hour) }

      before { stub_linked_transfer("ch_cart") }

      it "links the first sale when every sibling succeeded on the same date" do
        create(:purchase, link: create(:product), stripe_transaction_id: "ch_cart", succeeded_at: now - 20.days)

        deliver

        expect(expect_one_applied_deduction.financing_paydown_purchase).to eq(first_sale)
      end

      it "refuses to pick a sibling while another has not succeeded" do
        second_sale.update_columns(succeeded_at: nil, purchase_state: "in_progress")

        expect { deliver }.to raise_error(/did not all succeed on one date/)
        expect(capital_credits).to be_empty
      end

      it "refuses to pick a sibling when they succeeded on different dates" do
        first_sale.update_columns(succeeded_at: now - 3.days)

        expect { deliver }.to raise_error(/did not all succeed on one date/)
        expect(capital_credits).to be_empty
      end
    end
  end

  describe "choosing the balance" do
    before { stub_linked_transfer(nil) }

    it "debits the earliest unpaid balance and leaves paid ones alone" do
      paid = create(:balance, user: seller, merchant_account:, date: deducted_at.to_date, amount_cents: 500, state: "paid")
      earliest_unpaid = create(:balance, user: seller, merchant_account:, date: now.to_date - 3, amount_cents: 1000)
      create(:balance, user: seller, merchant_account:, date: now.to_date, amount_cents: 1000)

      deliver

      expect(expect_one_applied_deduction.balance).to eq(earliest_unpaid)
      expect(earliest_unpaid.reload.amount_cents).to eq(220)
      expect([paid.reload.amount_cents, paid.holding_amount_cents]).to eq([500, 500])
    end

    it "dates a new balance to the deduction when a delayed delivery finds no unpaid balance" do
      paid = create(:balance, user: seller, merchant_account:, date: deducted_at.to_date, amount_cents: 500, state: "paid")

      deliver

      balance = expect_one_applied_deduction.balance
      expect(balance).not_to eq(paid)
      expect([balance.date, balance.state, balance.amount_cents]).to eq([deducted_at.to_date, "unpaid", -780])
      expect([paid.reload.amount_cents, paid.state]).to eq([500, "paid"])
    end

    it "falls back to the event's creation time when the financing transaction has none" do
      event = capital_event
      event["data"]["object"].delete("created_at")
      event["created"] = (deducted_at + 1.day).to_i

      deliver(event)

      expect(expect_one_applied_deduction.balance.date).to eq(deducted_at.to_date + 1)
    end
  end

  describe "retries" do
    before { stub_linked_transfer(nil) }

    it "applies a saved credit whose transaction was never created" do
      allow(BalanceTransaction).to receive(:create!).and_raise("interrupted")
      expect { deliver }.to raise_error("interrupted")
      expect(capital_credits.sole.balance_transaction).to be_nil
      allow(BalanceTransaction).to receive(:create!).and_call_original

      2.times { deliver }

      expect_one_applied_deduction
    end

    it "applies a saved purchase-less credit found on redelivery" do
      credit = saved_account_withholding

      deliver

      expect(expect_one_applied_deduction).to eq(credit)
    end

    it "reuses the saved transaction when the balance update was interrupted" do
      allow_any_instance_of(BalanceTransaction).to receive(:update_balance!).and_raise("interrupted")
      expect { deliver }.to raise_error("interrupted")
      transaction_id = capital_credits.sole.balance_transaction.id
      allow_any_instance_of(BalanceTransaction).to receive(:update_balance!).and_call_original

      2.times { deliver }

      expect(expect_one_applied_deduction.balance_transaction.id).to eq(transaction_id)
    end

    it "links the credit without applying the transaction again after the final save fails" do
      allow_any_instance_of(Credit).to receive(:update!).and_raise("interrupted")
      expect { deliver }.to raise_error("interrupted")
      expect(capital_credits.sole.balance_transaction.balance_id).to be_present
      allow_any_instance_of(Credit).to receive(:update!).and_call_original

      2.times { deliver }

      expect(expect_one_applied_deduction.balance.amount_cents).to eq(-780)
    end

    it "refuses a redelivery with a different amount even after the credit is applied" do
      deliver
      credit = expect_one_applied_deduction

      expect { deliver(capital_event(amount: 781)) }.to raise_error(ArgumentError, /does not match/)
      expect(expect_one_applied_deduction.balance.amount_cents).to eq(credit.balance.amount_cents)
    end

    it "refuses to apply a transaction written for different money" do
      credit = saved_account_withholding
      amount = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: -1780, net_cents: -1780)
      BalanceTransaction.create!(user: seller, merchant_account:, credit:, issued_amount: amount, holding_amount: amount, update_user_balance: false)

      expect { deliver }.to raise_error(ArgumentError, /balance transaction does not match/)
      expect(credit.reload.balance_id).to be_nil
      expect(credit.balance_transaction.balance_id).to be_nil
    end
  end

  describe "currencies" do
    before { stub_linked_transfer(nil) }

    it "books a foreign-currency withholding at the rate it was first recorded" do
      merchant_account.update!(currency: Currency::GBP)
      allow_any_instance_of(Credit).to receive(:get_rate).with(Currency::GBP).and_return("0.8")
      allow(BalanceTransaction).to receive(:create!).and_raise("interrupted")
      expect { deliver(capital_event(amount: 800)) }.to raise_error("interrupted")
      allow(BalanceTransaction).to receive(:create!).and_call_original
      allow_any_instance_of(Credit).to receive(:get_rate).with(Currency::GBP).and_return("0.5")

      deliver(capital_event(amount: 800))

      credit = expect_one_applied_deduction(holding_cents: -800, issued_cents: -1000)
      expect([credit.amount_cents, credit.stripe_loan_paydown_currency, credit.stripe_loan_paydown_usd_rate]).to eq([-800, Currency::GBP, "0.8"])
      expect([credit.balance.currency, credit.balance.holding_currency]).to eq([Currency::USD, Currency::GBP])
    end

    it "keeps zero-decimal amounts in whole units" do
      merchant_account.update!(currency: Currency::JPY)
      allow_any_instance_of(Credit).to receive(:get_rate).with(Currency::JPY).and_return("150")

      deliver(capital_event(amount: 1500))

      credit = expect_one_applied_deduction(holding_cents: -1500, issued_cents: -1000)
      expect(credit.amount_cents).to eq(-1500)
    end

    it "refuses a redelivery once the account's currency no longer matches the recorded one" do
      merchant_account.update!(currency: Currency::GBP)
      allow_any_instance_of(Credit).to receive(:get_rate).with(Currency::GBP).and_return("0.8")
      allow(BalanceTransaction).to receive(:create!).and_raise("interrupted")
      expect { deliver(capital_event(amount: 800)) }.to raise_error("interrupted")
      allow(BalanceTransaction).to receive(:create!).and_call_original
      merchant_account.update!(currency: Currency::EUR)

      expect { deliver(capital_event(amount: 800)) }.to raise_error(ArgumentError, /does not match/)
      expect(capital_credits.sole.balance_transaction).to be_nil
    end
  end

  describe "existing records" do
    it "leaves a manual repayment with the same identifier unchanged" do
      manual = create(:credit, user: seller, merchant_account:, stripe_loan_paydown_id: financing_id, amount_cents: -780, balance: nil)
      expect(Stripe::Charge).not_to receive(:retrieve)

      deliver

      expect(manual.automatic_capital_deduction?).to be(false)
      expect(capital_credits.sole).to eq(manual)
      expect(manual.reload.balance_id).to be_nil
      expect(manual.balance_transaction).to be_nil
    end

    it "keeps refusing an old credit linked to a purchase that never succeeded" do
      failed_purchase = failed_purchase_without_charge
      credit = Credit.create!(user: seller, merchant_account:, amount_cents: -780, financing_paydown_purchase: failed_purchase, stripe_loan_paydown_id: financing_id)
      amount = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: -780, net_cents: -780)
      BalanceTransaction.create!(user: seller, merchant_account:, credit:, issued_amount: amount, holding_amount: amount, update_user_balance: false)
      expect(Stripe::Charge).not_to receive(:retrieve)

      expect { deliver }.to raise_error("Capital purchase has not succeeded yet")

      expect(credit.reload.financing_paydown_purchase).to eq(failed_purchase)
      expect([credit.balance_id, credit.balance_transaction.balance_id]).to eq([nil, nil])
      expect(credit.stripe_loan_paydown_reason).to be_nil
    end

    it "refuses to relink an old credit to another purchase" do
      failed_purchase = failed_purchase_without_charge
      Credit.create!(user: seller, merchant_account:, amount_cents: -780, financing_paydown_purchase: failed_purchase, stripe_loan_paydown_id: financing_id)

      expect do
        Credit.create_for_financing_paydown!(purchase: create(:purchase, link: product), merchant_account:, amount_cents: -780, stripe_loan_paydown_id: financing_id)
      end.to raise_error(ArgumentError, /does not match/)
      expect(capital_credits.sole.financing_paydown_purchase).to eq(failed_purchase)
    end

    it "does not treat a saved account withholding as a sale-linked one" do
      saved_account_withholding

      expect do
        Credit.create_for_financing_paydown!(purchase: create(:purchase, link: product), merchant_account:, amount_cents: -780, stripe_loan_paydown_id: financing_id)
      end.to raise_error(ArgumentError, /does not match/)
      expect(capital_credits.sole.balance_transaction).to be_nil
    end

    it "requires a purchase for a sale-linked deduction" do
      expect do
        Credit.create_for_financing_paydown!(purchase: nil, merchant_account:, amount_cents: -780, stripe_loan_paydown_id: financing_id)
      end.to raise_error(ArgumentError, /needs its purchase/)
      expect(capital_credits).to be_empty
    end
  end

  describe "validating the event" do
    before { stub_linked_transfer(nil) }

    def with_reason(event, reason)
      event["data"]["object"]["details"]["reason"] = reason
      event["data"]["object"]["user_facing_description"] = "Forced debit from Stripe Payments"
      event
    end

    it "refuses to finish a saved automatic credit from an event with another reason" do
      credit = saved_account_withholding

      %w[collection adjustment].each do |reason|
        expect { deliver(with_reason(capital_event, reason)) }.to raise_error(ArgumentError, /does not match/)
      end
      expect(credit.reload.balance_transaction).to be_nil
      expect(credit.balance_id).to be_nil
    end

    it "refuses an event with another reason even after the automatic credit is applied" do
      deliver
      balance_cents = expect_one_applied_deduction.balance.amount_cents

      expect { deliver(with_reason(capital_event, "collection")) }.to raise_error(ArgumentError, /does not match/)
      expect(expect_one_applied_deduction.balance.amount_cents).to eq(balance_cents)
    end

    it "refuses a direct application for another reason" do
      credit = saved_account_withholding

      expect { credit.apply_financing_paydown!(reason: "collection") }.to raise_error(ArgumentError, /does not match/)
      expect { credit.apply_financing_paydown!(merchant_account:, amount_cents: -780, currency: nil) }.to raise_error(ArgumentError, /does not match/)
      expect(credit.reload.balance_transaction).to be_nil
    end

    it "refuses to apply a credit that belongs to another seller" do
      credit = saved_account_withholding(user: create(:user))

      expect { credit.apply_financing_paydown!(merchant_account:, amount_cents: -780, currency: Currency::USD) }.to raise_error(ArgumentError, /does not match/)
      expect(credit.reload.balance_transaction).to be_nil
    end

    [0, -780, "780", 780.5, nil].each do |total_amount|
      it "records nothing for a total_amount of #{total_amount.inspect}" do
        expect(Stripe::Charge).not_to receive(:retrieve)

        expect { deliver(capital_event(amount: total_amount)) }.to raise_error(ArgumentError, /positive integer/)
        expect(capital_credits).to be_empty
      end
    end

    it "does not finish a saved credit from an event without a valid total" do
      credit = saved_account_withholding

      expect { deliver(capital_event(amount: 0)) }.to raise_error(ArgumentError, /positive integer/)
      expect(credit.reload.balance_transaction).to be_nil
    end

    it "keeps reading a manual collection total as before" do
      stub_const("GUMROAD_ADMIN_ID", create(:admin_user).id)

      deliver(with_reason(capital_event(amount: "2000"), "collection"))

      credit = capital_credits.sole
      expect([credit.amount_cents, credit.automatic_capital_deduction?, credit.balance.amount_cents]).to eq([-2000, false, -2000])
    end

    it "refuses to create a deduction that is not a negative integer" do
      [0, 780, -780.0].each do |amount_cents|
        expect do
          Credit.create_for_account_capital_withholding!(amount_cents:, merchant_account:, stripe_loan_paydown_id: financing_id, deducted_at: deducted_at.to_i)
        end.to raise_error(ArgumentError, /negative integer/)
      end
      expect(capital_credits).to be_empty
    end

    it "refuses to apply a saved credit that would add funds" do
      credit = saved_account_withholding(amount_cents: 780, stripe_loan_paydown_usd_cents: 780)

      expect { credit.apply_financing_paydown! }.to raise_error(ArgumentError, /must be negative/)
      expect(credit.reload.balance_transaction).to be_nil
    end

    ["not-a-time", "", 0, -1, 17.5].each do |created_at|
      it "records nothing when the deduction time is #{created_at.inspect}" do
        expect { deliver(capital_event(created_at:)) }.to raise_error(ArgumentError, /no valid deduction time/)
        expect(capital_credits).to be_empty
      end
    end

    it "records nothing when neither the transaction nor the event has a time" do
      event = capital_event
      event["data"]["object"].delete("created_at")
      event.delete("created")

      expect { deliver(event) }.to raise_error(ArgumentError, /no valid deduction time/)
      expect(capital_credits).to be_empty
    end

    it "accepts a numeric string time" do
      deliver(capital_event(created_at: deducted_at.to_i.to_s))

      expect(expect_one_applied_deduction.balance.date).to eq(deducted_at.to_date)
    end
  end

  describe "payout reporting" do
    before { stub_linked_transfer(nil) }

    def reported_loan_repayment_cents
      seller.sales_data_for_balance_ids(seller.unpaid_balances.map(&:id)).values_at(:loan_repayment_cents, :credits_cents)
    end

    it "reports a pound withholding in the dollars it booked" do
      merchant_account.update!(currency: Currency::GBP)
      allow_any_instance_of(Credit).to receive(:get_rate).with(Currency::GBP).and_return("0.8")

      deliver(capital_event(amount: 800))

      expect(reported_loan_repayment_cents).to eq([-1000, 0])
    end

    it "reports a yen withholding in the dollars it booked" do
      merchant_account.update!(currency: Currency::JPY)
      allow_any_instance_of(Credit).to receive(:get_rate).with(Currency::JPY).and_return("150")

      deliver(capital_event(amount: 1500))

      expect(reported_loan_repayment_cents).to eq([-1000, 0])
    end

    it "keeps reporting manual and dollar repayments at their amount" do
      stub_const("GUMROAD_ADMIN_ID", create(:admin_user).id)
      Credit.create_for_manual_paydown_on_stripe_loan!(amount_cents: -2000, merchant_account:, stripe_loan_paydown_id: "cptxn_manual_repayment")

      deliver

      expect(reported_loan_repayment_cents).to eq([-2780, 0])
    end
  end
end
