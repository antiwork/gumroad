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
      hash_including(idempotency_key: "#{dedupe_key}:0:72850")
    )

    described_class.new.perform
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id))
  end

  it "funds only the incremental delta when a reconciled shortfall grows before leg two lands" do
    residue_row(-100_00)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)
    dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)

    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(hash_including(amount_cents: 100_00)).once
    described_class.new.perform
    expect($redis.get(dedupe_key).to_i).to eq(100_00)

    residue_row(-150_00) # total shortfall is now 250_00 cents across both rows

    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(
      hash_including(amount_cents: 150_00, idempotency_key: "#{dedupe_key}:10000:25000")
    )

    described_class.new.perform

    expect($redis.get(dedupe_key).to_i).to eq(250_00)
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id))
  end

  it "funds a new independent shortfall instead of treating it as already covered, once the old funded rows are reconciled" do
    old_row = residue_row(-100_00)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)

    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(hash_including(amount_cents: 100_00)).once
    described_class.new.perform

    # Leg two reconciles: the old row is paid off and a new, unrelated shortfall lands.
    old_row.mark_processing!
    old_row.mark_paid!
    residue_row(-50_00)

    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(hash_including(amount_cents: 50_00)).once
    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async).with(anything, anything, a_string_including("ESCALATE")).exactly(0).times
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id))
  end

  it "keeps escalating without a second transfer when the shortfall is unchanged or has shrunk" do
    residue_row(-100_00)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)
    dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)

    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(hash_including(amount_cents: 100_00)).once
    described_class.new.perform

    expect(StripeTransferInternallyToCreator).not_to receive(:transfer_funds_to_account)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async).with(anything, anything, a_string_including("ESCALATE")).once
    expect($redis.get(dedupe_key).to_i).to eq(100_00)
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id))
  end

  it "does not release the dedupe claim on an ambiguous Stripe error, so the candidate escalates rather than retries blind" do
    residue_row(-728_50)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)
    dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)

    allow(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).and_raise(Stripe::APIConnectionError.new("connection dropped"))
    described_class.new.perform

    expect($redis.get(RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id))).to be_nil # leg-two claim untouched by a transfer-scoped claim
    transfer_key = "#{dedupe_key}:0:72850"
    expect($redis.get(transfer_key)).not_to be_nil # held, not released — next run must not blindly retry
    expect($redis.ttl(transfer_key)).to eq(-1) # persisted: only a human clearing it can unblock a retry, never a lapsed TTL

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to include("ERROR")
      expect(message).to include("APIConnectionError")
    end
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id))
    $redis.del("#{RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)}:0:72850")
  end

  it "releases the dedupe claim on a validation-style Stripe error, so the candidate is retryable" do
    residue_row(-728_50)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)
    dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)

    allow(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).and_raise(Stripe::InvalidRequestError.new("bad param", nil))
    described_class.new.perform

    transfer_key = "#{dedupe_key}:0:72850"
    expect($redis.get(transfer_key)).to be_nil # released — safe to retry next run

    allow(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).and_call_original
    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).once

    described_class.new.perform
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id))
    $redis.del("#{RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)}:0:72850")
  end

  it "does not overfund when only one of two previously-funded rows reconciles, leaving the other still outstanding" do
    row_a = residue_row(-100_00)
    residue_row(-150_00)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)
    dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)

    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(hash_including(amount_cents: 250_00)).once
    described_class.new.perform

    # Only row_a reconciles; row_b (still unpaid, still funded) survives — partial reconciliation.
    row_a.mark_processing!
    row_a.mark_paid!

    expect(StripeTransferInternallyToCreator).not_to receive(:transfer_funds_to_account)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async).with(anything, anything, a_string_including("ESCALATE")).once
    expect($redis.get(dedupe_key).to_i).to eq(250_00) # unchanged — row_b's funding credit must survive row_a's reconciliation
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id))
  end

  it "serializes overlapping runs for the same account so a stale read cannot produce two transfers for one shortfall" do
    residue_row(-100_00)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)
    dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)
    lock_key = "#{dedupe_key}:lock"

    # Simulate a concurrent run already holding the per-account lock.
    $redis.set(lock_key, 1, ex: 60, nx: true)

    expect(StripeTransferInternallyToCreator).not_to receive(:transfer_funds_to_account)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async).with(anything, anything, a_string_including("already in progress")).once
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id))
    $redis.del("#{RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)}:lock")
  end

  it "holds the per-account lock long enough to outlive a real Stripe call, not just the local read-decide step" do
    residue_row(-100_00)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)
    dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)
    lock_key = "#{dedupe_key}:lock"
    allow($redis).to receive(:set).and_call_original

    described_class.new.perform

    # By the time perform returns the lock is released again, so assert the TTL it was set with
    # rather than its live value — an expired-mid-call lock would have let a second run acquire it.
    worst_case_stripe_call = Stripe.read_timeout * (Stripe.max_network_retries + 1)
    expect(described_class::LOCK_TTL).to be > worst_case_stripe_call.seconds
    expect($redis).to have_received(:set).with(lock_key, anything, ex: described_class::LOCK_TTL.to_i, nx: true)
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(dedupe_key)
    $redis.del(lock_key)
  end

  it "credits only the surviving funded rows, not the whole prior aggregate, so a new shortfall next to an untouched funded row is not suppressed" do
    row_a = residue_row(-100_00)
    residue_row(-200_00)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)

    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(hash_including(amount_cents: 300_00)).once
    described_class.new.perform

    # row_a reconciles; row_b (still funded) survives; a brand-new, unrelated row_c lands alongside it.
    row_a.mark_processing!
    row_a.mark_paid!
    residue_row(-50_00)

    # Only row_b's 200_00 credit should carry forward — the aggregate 300_00 must not swallow row_c's
    # new 50_00 shortfall (the exact "Aggregate credit suppresses new negative rows" scenario).
    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(hash_including(amount_cents: 50_00)).once
    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async).with(anything, anything, a_string_including("ESCALATE")).exactly(0).times
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id))
  end

  it "persists the transfer claim the instant Stripe accepts, before the funded-state write, so a crash in between can't be retried once the local TTL lapses" do
    residue_row(-728_50)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)
    dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)
    transfer_key = "#{dedupe_key}:0:72850"

    described_class.new.perform

    expect($redis.ttl(transfer_key)).to eq(-1) # persisted, not left on the 7-day TTL
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id))
    $redis.del("#{RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)}:0:72850")
  end

  it "does not release a lock held by a different run's token, so a CAS race can't let a third run in early" do
    dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)
    lock_key = "#{dedupe_key}:lock"
    $redis.set(lock_key, "someone-elses-token", nx: true)

    # Simulates this job's own release firing after its lock already expired and got reacquired
    # by a second run — the CAS comparison must refuse to delete a token it didn't set.
    $redis.eval(described_class::LOCK_RELEASE_SCRIPT, keys: [lock_key], argv: ["stale-token"])

    expect($redis.get(lock_key)).to eq("someone-elses-token")
  ensure
    $redis.del(lock_key)
  end

  it "escalates a grown shortfall rather than computing a delta against funded_cents while a prior transfer's outcome is unresolved" do
    residue_row(-100_00)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)
    dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)

    allow(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).and_raise(Stripe::APIConnectionError.new("connection dropped"))
    described_class.new.perform
    expect($redis.get("#{dedupe_key}:unresolved")).to eq("10000")

    # The shortfall grows before the ambiguous Stripe outcome is resolved — must not fund the
    # naive delta (which would ignore the possibly-already-sent 100_00 and risk overfunding).
    residue_row(-50_00)
    expect(StripeTransferInternallyToCreator).not_to receive(:transfer_funds_to_account)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async).with(anything, anything, a_string_including("ambiguous Stripe outcome")).once
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(dedupe_key)
    $redis.del("#{dedupe_key}:unresolved")
    $redis.del("#{dedupe_key}:0:10000")
  end
end
