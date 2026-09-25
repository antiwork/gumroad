# frozen_string_literal: true

require "spec_helper"

RSpec.describe ScheduledPayout do
  let(:user) { create(:user) }
  let(:merchant_account) { create(:merchant_account, user:, currency: Currency::HUF, charge_processor_merchant_id: "acct_currency_groups") }
  let!(:bank_account) { create(:ach_account, user:) }
  let!(:huf_balance) do
    create(:balance, user:, merchant_account:, date: 3.days.ago.to_date,
                     amount_cents: 100_00, holding_currency: Currency::HUF, holding_amount_cents: 35_000_00)
  end
  let!(:eur_balance) do
    create(:balance, user:, merchant_account:, date: 2.days.ago.to_date,
                     amount_cents: 100_00, holding_currency: Currency::EUR, holding_amount_cents: 90_00)
  end
  let(:scheduled_payout) { create(:scheduled_payout, user:, action: "payout", processor: PayoutProcessorType::STRIPE, payout_amount_cents: 200_00) }

  before do
    allow(StripePayoutProcessor).to receive(:pay_out_currencies).and_return([Currency::EUR])
    allow(StripePayoutProcessor).to receive(:cross_border_payout?).and_return(false)
    allow(Stripe::Balance).to receive(:retrieve).and_return(
      Stripe::Balance.construct_from(available: [{ currency: "huf", amount: 35_000_00 }, { currency: "eur", amount: 90_00 }], pending: [])
    )
    allow(Stripe::Payout).to receive(:create).and_return(Stripe::Payout.construct_from(id: "po_currency_group", arrival_date: 2.days.from_now.to_i))
    allow(ErrorNotifier).to receive(:notify)
  end

  it "dispatches the first currency when the second preparation raises and releases only the failed claim" do
    calls = 0
    allow(Stripe::Balance).to receive(:retrieve).and_wrap_original do
      calls += 1
      raise Stripe::APIConnectionError, "second currency unavailable" if calls == 2

      Stripe::Balance.construct_from(available: [{ currency: "huf", amount: 35_000_00 }], pending: [])
    end
    expect(Stripe::Payout).to receive(:create).with(hash_including(currency: Currency::HUF, amount: 35_000_00), anything).once

    expect { scheduled_payout.execute! }.to raise_error(RuntimeError, /second currency unavailable/)

    expect(calls).to eq(2)
    healthy_payment = huf_balance.reload.payments.sole
    failed_payment = eur_balance.reload.payments.sole
    expect(healthy_payment).to be_processing
    expect(healthy_payment.stripe_transfer_id).to eq("po_currency_group")
    expect(failed_payment).to be_failed
    expect(failed_payment.error_message).to include("second currency unavailable")
    expect(eur_balance).to be_unpaid
    expect(user.balances.processing.ids).to eq([huf_balance.id])
    expect(user.balances.processing.all? { |balance| balance.payments.processing.exists? }).to eq(true)
    expect(scheduled_payout.reload).to be_pending
  end

  it "dispatches the healthy batch payment when the second currency fails preparation" do
    calls = 0
    allow(Stripe::Balance).to receive(:retrieve) do
      calls += 1
      raise Stripe::APIConnectionError, "second currency unavailable" if calls == 2

      Stripe::Balance.construct_from(available: [{ currency: "huf", amount: 35_000_00 }], pending: [])
    end
    expect(Stripe::Payout).to receive(:create).with(hash_including(currency: Currency::HUF), anything).once

    payments = PayoutUsersService.new(date_string: Date.yesterday.to_s, processor_type: PayoutProcessorType::STRIPE, user_ids: user.id).process

    expect(calls).to eq(2)
    expect(payments).to eq([huf_balance.reload.payments.sole])
    expect(payments.sole.stripe_transfer_id).to eq("po_currency_group")
    expect(eur_balance.reload).to be_unpaid
    expect(eur_balance.payments.sole).to be_failed
  end

  %w[scheduled batch].each do |entry_point|
    it "dispatches the second #{entry_point} currency even when the first payout raises with an unknown outcome" do
      allow(Stripe::Payout).to receive(:create).with(hash_including(currency: Currency::HUF), anything)
        .and_raise(Stripe::APIConnectionError, "payout outcome unknown")
      expect(Stripe::Payout).to receive(:create).with(hash_including(currency: Currency::EUR), anything).once

      expect do
        if entry_point == "scheduled"
          scheduled_payout.execute!
        else
          PayoutUsersService.new(date_string: Date.yesterday.to_s, processor_type: PayoutProcessorType::STRIPE, user_ids: user.id).process
        end
      end.to raise_error(Stripe::APIConnectionError, /payout outcome unknown/)

      expect(huf_balance.reload.payments.sole.failure_reason).to eq(Payment::FailureReason::PAYOUT_OUTCOME_UNKNOWN)
      expect(user.reload).to be_payouts_paused_internally
      expect(eur_balance.reload.payments.sole.stripe_transfer_id).to eq("po_currency_group")
    end
  end

  it "rolls back every claim and payment if saving the second group fails before preparation" do
    saves = 0
    allow_any_instance_of(Payment).to receive(:save!).and_wrap_original do |original, *args, **kwargs|
      saves += 1
      raise ActiveRecord::RecordNotSaved, "second group save failed" if saves == 2

      original.call(*args, **kwargs)
    end
    expect(Stripe::Payout).not_to receive(:create)
    expect(StripePayoutProcessor).not_to receive(:prepare_payment_and_set_amount)

    expect { scheduled_payout.execute! }.to raise_error(ActiveRecord::RecordNotSaved, /second group save failed/)

    expect(saves).to eq(2)
    expect(user.payments.count).to eq(0)
    expect(user.balances.processing.count).to eq(0)
    expect(user.balances.unpaid.ids).to contain_exactly(huf_balance.id, eur_balance.id)
    expect(scheduled_payout.reload).to be_pending
  end

  it "pays the healthy currency when a foreign sale and its refund leave that group netting zero" do
    allow(StripePayoutProcessor).to receive(:pay_out_currencies).and_return([])
    eur_refund = create(:balance, user:, merchant_account:, date: 2.days.ago.to_date,
                                  amount_cents: -100_00, holding_currency: Currency::EUR, holding_amount_cents: -90_00)
    expect(Stripe::Payout).to receive(:create).with(hash_including(currency: Currency::HUF), anything).once

    payments = PayoutUsersService.new(date_string: Date.yesterday.to_s, processor_type: PayoutProcessorType::STRIPE, user_ids: user.id).process

    expect(eur_balance.reload).to be_unpaid
    expect(eur_refund.reload).to be_unpaid
    expect(payments).to eq([huf_balance.reload.payments.sole])
  end

  it "pays the healthy currency net of a debt in a currency the account cannot pay out" do
    allow(StripePayoutProcessor).to receive(:pay_out_currencies).and_return([])
    eur_refund = create(:balance, user:, merchant_account:, date: 2.days.ago.to_date,
                                  amount_cents: -150_00, holding_currency: Currency::EUR, holding_amount_cents: -135_00)
    huf_newest = create(:balance, user:, merchant_account:, date: 2.days.ago.to_date,
                                  amount_cents: 60_00, holding_currency: Currency::HUF, holding_amount_cents: 21_000_00)
    expect(Stripe::Payout).to receive(:create).with(hash_including(currency: Currency::HUF), anything).once

    payments = PayoutUsersService.new(date_string: Date.yesterday.to_s, processor_type: PayoutProcessorType::STRIPE, user_ids: user.id).process

    expect(payments).to eq([huf_balance.reload.payments.sole])
    expect([huf_newest, eur_balance, eur_refund].map { |balance| balance.reload.state }.uniq).to eq(["unpaid"])
  end

  it "blocks every group when the seller really owes money in one of the currencies" do
    create(:balance, user:, merchant_account:, date: 2.days.ago.to_date,
                     amount_cents: -150_00, holding_currency: Currency::EUR, holding_amount_cents: -135_00)
    expect(Stripe::Payout).not_to receive(:create)

    payments = PayoutUsersService.new(date_string: Date.yesterday.to_s, processor_type: PayoutProcessorType::STRIPE, user_ids: user.id).process

    expect(payments).to eq([])
    expect(user.balances.processing.count).to eq(0)
    expect(huf_balance.reload).to be_unpaid
    expect(eur_balance.reload).to be_unpaid
  end
end
