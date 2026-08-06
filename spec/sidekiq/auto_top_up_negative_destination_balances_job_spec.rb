# frozen_string_literal: true

require "spec_helper"

describe AutoTopUpNegativeDestinationBalancesJob do
  let(:seller) { create(:user) }
  let(:in_cycle_date) { User::PayoutSchedule.next_scheduled_payout_end_date - 1 }
  let(:merchant_account) do
    create(:merchant_account, user: seller, charge_processor_id: StripeChargeProcessor.charge_processor_id,
                              charge_processor_merchant_id: "acct_autotopup_#{SecureRandom.hex(6)}",
                              currency: Currency::PHP, country: "PH")
  end

  def residue_row(cents, date: in_cycle_date)
    create(:balance, user: seller, merchant_account:, date:,
                     amount_cents: 0, holding_currency: Currency::PHP, holding_amount_cents: cents)
  end

  def make_payable(cents = 200_00)
    create(:balance, user: seller, merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id),
                     date: in_cycle_date, amount_cents: cents, holding_amount_cents: cents)
    seller.reload
  end

  before do
    allow(InternalNotificationWorker).to receive(:perform_async)
  end

  it "stays silent when nothing is payable" do
    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "dry-runs by default without calling Stripe" do
    residue_row(-728_50)
    make_payable

    expect(StripeTransferInternallyToCreator).not_to receive(:transfer_funds_to_account)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |room, subject, message|
      expect(room).to eq("payouts")
      expect(subject).to eq("Negative destination balance top-ups")
      expect(message).to include("DRY RUN")
      expect(message).to include("would top up 1 of 1 candidates")
    end
  end

  it "transfers funds to close the gap when the flag is live" do
    residue_row(-728_50)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)

    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(
      hash_including(stripe_account_id: merchant_account.charge_processor_merchant_id, currency: Currency::PHP, amount_cents: 728_50)
    )

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to start_with("Topped up 1 of 1 candidates")
    end
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
  end

  it "does not repeat a transfer for an unchanged candidate on a later run" do
    residue_row(-728_50)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)

    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).once

    described_class.new.perform
    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async).with(anything, anything, a_string_including("ESCALATE")).once
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id))
  end

  it "withholds a post-cutoff-only candidate for human review instead of transferring" do
    residue_row(-728_50)
    make_payable
    allow(AlertOnNegativeDestinationBalancesJob).to receive(:scan).and_wrap_original do |original|
      result = original.call
      result[:payable] = result[:payable].map { |entry| entry.merge(post_cutoff: true) }
      result
    end
    Feature.activate(:auto_topup_negative_destination_balances)

    expect(StripeTransferInternallyToCreator).not_to receive(:transfer_funds_to_account)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to include("ESCALATE")
      expect(message).to include("post-cutoff")
    end
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
  end

  it "escalates a RETIRED merchant account instead of attempting a transfer" do
    residue_row(-728_50)
    make_payable
    merchant_account.mark_deleted!
    Feature.activate(:auto_topup_negative_destination_balances)

    expect(StripeTransferInternallyToCreator).not_to receive(:transfer_funds_to_account)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to include("ESCALATE")
      expect(message).to include("RETIRED")
    end
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
  end

  it "turns a Stripe failure into a named error line without stopping the run" do
    residue_row(-728_50)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)

    allow(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).and_raise(Stripe::InvalidRequestError.new("boom", nil))

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to include("ERROR")
      expect(message).to include("boom")
    end
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
  end

  it "releases the dedupe claim on a Stripe failure so the next run can retry instead of being blocked for 7 days" do
    residue_row(-728_50)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)

    allow(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).and_raise(Stripe::InvalidRequestError.new("boom", nil))
    described_class.new.perform

    expect($redis.get(RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id))).to be_nil

    allow(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).and_call_original
    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).once

    described_class.new.perform
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id))
  end

  it "refreshes the dedupe TTL instead of letting it lapse while a candidate is still outstanding" do
    residue_row(-728_50)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)

    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).once

    described_class.new.perform
    dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)
    $redis.expire(dedupe_key, 1.hour)

    described_class.new.perform

    expect($redis.ttl(dedupe_key)).to be > 1.hour
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id))
  end

  it "passes a stable idempotency key to Stripe so an ambiguous local retry doesn't double-transfer" do
    residue_row(-728_50)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)
    dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)

    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(
      hash_including(idempotency_key: dedupe_key)
    )

    described_class.new.perform
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id))
  end
end
