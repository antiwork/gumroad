# frozen_string_literal: true

require "spec_helper"

describe AutoTopUpNegativeDestinationBalancesJob do
  let(:seller) { create(:user, email: "seller@example.com") }
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

  # Mirrors the job's own row_fingerprint so specs can predict a transfer_key without
  # hardcoding an id-dependent hash.
  def fingerprint_for(*balance_ids)
    Digest::SHA1.hexdigest(balance_ids.join("-"))[0, 12]
  end

  # USD → local rates; stubbed on the job because the shared Redis currencies namespace is flushed
  # by other spec processes.
  RATES = { "php" => "2.0", "lak" => "20000.0", "jpy" => "100.0" }.freeze

  def usd_for(local_cents, currency: Currency::PHP)
    (BigDecimal(local_cents.to_s) / BigDecimal(RATES.fetch(currency.to_s.downcase)) *
      (1 + described_class::USD_TOPUP_BUFFER_RATIO)).ceil.to_i
  end

  before do
    allow(InternalNotificationWorker).to receive(:perform_async)
    allow_any_instance_of(described_class).to receive(:get_rate) { |_job, currency| RATES[currency.to_s.downcase] }
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
      hash_including(stripe_account_id: merchant_account.charge_processor_merchant_id, currency: Currency::USD, amount_cents: usd_for(728_50),
                     metadata: hash_including(destination_hole_cents: 728_50, destination_currency: Currency::PHP))
    )

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to start_with("Topped up 1 of 1 candidates")
    end
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
  end

  it "funds a payable LAK destination past refund-netted accounts at the scan cap" do
    stub_const("AlertOnNegativeDestinationBalancesJob::MAX_CANDIDATES_SCANNED", 1)
    stub_const("AlertOnNegativeDestinationBalancesJob::USER_BATCH_SIZE", 1)
    earlier_seller = create(:user)
    earlier_account = create(:merchant_account, user: earlier_seller,
                                                charge_processor_merchant_id: "acct_netted_#{SecureRandom.hex(6)}")
    create(:balance, user: earlier_seller, merchant_account: earlier_account, date: in_cycle_date,
                     amount_cents: -100, holding_amount_cents: -100)
    merchant_account.update!(currency: "lak", country: "LA")
    row = create(:balance, user: seller, merchant_account:, date: in_cycle_date,
                           amount_cents: 0, holding_currency: "lak", holding_amount_cents: -10_000_00)
    seller.update!(payout_threshold_cents: 100_00)
    make_payable(125_00)
    3.times do |week|
      create(:payment, user: seller, processor: PayoutProcessorType::STRIPE, state: "failed",
                       failure_reason: Payment::FailureReason::DESTINATION_LEDGER_NEGATIVE,
                       amount_cents: 0, created_at: (week + 1).weeks.ago)
    end
    dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)
    expect(earlier_seller.id).to be < seller.id
    expect(merchant_account).to be_alive
    expect(seller.unpaid_balance_cents_up_to_date(in_cycle_date)).to eq(125_00)
    expect($redis.get(dedupe_key)).to be_nil
    Feature.activate(:auto_topup_negative_destination_balances)

    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(
      hash_including(stripe_account_id: merchant_account.charge_processor_merchant_id, currency: Currency::USD, amount_cents: usd_for(10_000_00, currency: "lak"))
    )

    described_class.new.perform

    expect($redis.get(dedupe_key)).to eq("1000000:#{row.id}")
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

  it "re-reads the Balance rows instead of trusting the scan snapshot, so a reconciliation between scan and transfer noops instead of transferring a stale amount" do
    row = residue_row(-728_50)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)

    # A leg-two reconciliation pass (or a payout, refund, or credit) can zero this row after
    # `scan` already captured it but before this account's turn to transfer — the mechanism
    # T-Rex's stale-snapshot finding proved.
    allow(AlertOnNegativeDestinationBalancesJob).to receive(:scan).and_wrap_original do |original|
      result = original.call
      row.update!(holding_amount_cents: 0)
      result
    end

    expect(StripeTransferInternallyToCreator).not_to receive(:transfer_funds_to_account)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to start_with("Topped up 0 of 1 candidates")
    end
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
  end

  it "includes rows created after the scan in the transfer decision and idempotency fingerprint" do
    row = residue_row(-100_00)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)
    dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)
    new_row = nil

    allow(AlertOnNegativeDestinationBalancesJob).to receive(:scan).and_wrap_original do |original|
      result = original.call
      new_row = residue_row(-50_00)
      result
    end

    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(
      hash_including(
        amount_cents: usd_for(150_00),
        idempotency_key: satisfy { |key| key == "#{dedupe_key}:#{fingerprint_for(row.id, new_row.id)}:0:15000" }
      )
    )

    described_class.new.perform
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(dedupe_key) if dedupe_key
    $redis.del("#{dedupe_key}:#{fingerprint_for(row.id, new_row&.id)}:0:15000") if dedupe_key && new_row
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

  it "re-reads on the cycle window, not the whole ledger, when a post-cutoff credit would otherwise mask an in-cycle shortfall" do
    in_cycle_row = residue_row(-728_50)
    post_cutoff_credit = create(:balance, user: seller, merchant_account:,
                                          date: User::PayoutSchedule.next_scheduled_payout_end_date + 1,
                                          amount_cents: 0, holding_currency: Currency::PHP, holding_amount_cents: 728_50)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)

    # Whole ledger nets to 0 (the post-cutoff credit offsets the in-cycle shortfall), but the
    # cycle window the weekly run actually pays is still -728_50 — the window resolve_entry's
    # full_total used and the one this re-read must preserve.
    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(
      hash_including(amount_cents: usd_for(728_50))
    )

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to start_with("Topped up 1 of 1 candidates")
    end
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id))
    _ = [in_cycle_row, post_cutoff_credit]
  end

  it "does not resend the original shortfall when a later post-cutoff debit lands beside the funded row (two runs)" do
    in_cycle_row = residue_row(-728_50)
    post_cutoff_credit = create(:balance, user: seller, merchant_account:,
                                          date: User::PayoutSchedule.next_scheduled_payout_end_date + 1,
                                          amount_cents: 0, holding_currency: Currency::PHP, holding_amount_cents: 728_50)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)
    dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)

    # Run 1: whole ledger nets to 0 (post-cutoff credit offsets it), so the cycle window
    # (-728_50, the more negative of the two) is what's funded — same setup as the
    # window-selection spec above. The funded credit this stores must be scoped to the WINDOW
    # (in_cycle_row only), not the whole current row set (which also includes the post-cutoff
    # credit row) — that's the bug this spec pins.
    call_count = 0
    allow(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account) { call_count += 1 }

    described_class.new.perform
    expect(call_count).to eq(1)

    # Run 2: in_cycle_row is still unreconciled (leg two hasn't happened) and a brand-new
    # post-cutoff debit lands. Whole ledger becomes -100_00 (less negative than the in-cycle
    # window's -728_50), so the window is still in-cycle — current_total_cents is unchanged at
    # -728_50, i.e. still the SAME shortfall this account was already funded for. If the stored
    # funded credit wrongly included the post-cutoff credit row, its signed sum would net to 0
    # against the unrelated new debit and the comparison below would see "no credit," resending
    # the full 728_50 that was already transferred in run 1.
    create(:balance, user: seller, merchant_account:,
                     date: User::PayoutSchedule.next_scheduled_payout_end_date + 1,
                     amount_cents: 0, holding_currency: Currency::PHP, holding_amount_cents: -100_00)

    described_class.new.perform
    expect(call_count).to eq(1)

    expect(InternalNotificationWorker).to have_received(:perform_async).with(anything, anything, a_string_including("ESCALATE", "already topped up 728")).once
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(dedupe_key) if dedupe_key
    $redis.del("#{dedupe_key}:#{fingerprint_for(in_cycle_row.id)}:0:72850") if dedupe_key
    _ = post_cutoff_credit
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

  it "allows a retry after a rejected Stripe request instead of blocking it for 7 days" do
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
    row = residue_row(-728_50)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)
    dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)

    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(
      hash_including(idempotency_key: "#{dedupe_key}:#{fingerprint_for(row.id)}:0:72850")
    )

    described_class.new.perform
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id))
  end

  it "funds only the incremental delta when a reconciled shortfall grows before leg two lands" do
    row1 = residue_row(-100_00)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)
    dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)

    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(hash_including(amount_cents: usd_for(100_00))).once
    described_class.new.perform
    expect($redis.get(dedupe_key).to_i).to eq(100_00)

    row2 = residue_row(-150_00) # total shortfall is now 250_00 cents across both rows

    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(
      hash_including(amount_cents: usd_for(150_00), idempotency_key: "#{dedupe_key}:#{fingerprint_for(row1.id, row2.id)}:10000:25000")
    )

    described_class.new.perform

    expect($redis.get(dedupe_key).to_i).to eq(250_00)
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id))
  end

  it "credits a mixed-sign funded set on the same signed basis as full_total, so a smaller net increment is still funded" do
    residue_row(15_00_00)
    residue_row(-20_00_00)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)

    # Net shortfall is 50,000 cents (150,000 - 200,000).
    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(hash_including(amount_cents: usd_for(5_00_00))).once
    described_class.new.perform

    # A new -30,000-cent row lands: net shortfall grows to 80,000 cents, a 30,000-cent increment.
    # The bug summed |150,000| + |-200,000| = 350,000 cents of "credit" and withheld this entirely.
    residue_row(-3_00_00)
    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(hash_including(amount_cents: usd_for(3_00_00))).once

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async).with(anything, anything, a_string_including("ESCALATE")).exactly(0).times
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id))
  end

  it "funds a new independent shortfall instead of treating it as already covered, once the old funded rows are reconciled" do
    old_row = residue_row(-100_00)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)

    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(hash_including(amount_cents: usd_for(100_00))).once
    described_class.new.perform

    # Leg two reconciles: the old row is paid off and a new, unrelated shortfall lands.
    old_row.mark_processing!
    old_row.mark_paid!
    residue_row(-50_00)

    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(hash_including(amount_cents: usd_for(50_00))).once
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

    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(hash_including(amount_cents: usd_for(100_00))).once
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
    row = residue_row(-728_50)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)
    dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)

    allow(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).and_raise(Stripe::APIConnectionError.new("connection dropped"))
    described_class.new.perform

    expect($redis.get(RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id))).to be_nil # leg-two claim untouched by a transfer-scoped claim
    transfer_key = "#{dedupe_key}:#{fingerprint_for(row.id)}:0:72850"
    expect($redis.get(transfer_key)).not_to be_nil # held, not released — next run must not blindly retry
    expect($redis.ttl(transfer_key)).to eq(-1) # persisted: only a human clearing it can unblock a retry, never a lapsed TTL

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to include("ERROR")
      expect(message).to include("APIConnectionError")
    end
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id))
    $redis.del("#{RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)}:#{fingerprint_for(row.id)}:0:72850")
  end

  it "escalates distinctly when Redis persist fails after an ambiguous Stripe error, instead of leaving the claim on its 7-day TTL" do
    row = residue_row(-728_50)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)
    dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)
    transfer_key = "#{dedupe_key}:#{fingerprint_for(row.id)}:0:72850"

    allow(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).and_raise(Stripe::APIConnectionError.new("connection dropped"))
    allow($redis).to receive(:persist).with(transfer_key).and_raise(Redis::BaseConnectionError.new("blip")).at_least(:once)
    described_class.new.perform

    expect($redis.get(transfer_key)).not_to be_nil # held, not released
    expect($redis.ttl(transfer_key)).to be_within(2).of(604_800) # persist never landed — still on the original 7-day TTL, not confirmed persisted

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to include("ESCALATE")
      expect(message).to include("could not be confirmed in Redis")
    end
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id))
    $redis.del("#{RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)}:#{fingerprint_for(row.id)}:0:72850")
  end

  it "retains a retryable marker on a validation-style Stripe error" do
    row = residue_row(-728_50)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)
    dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)

    allow(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).and_raise(Stripe::InvalidRequestError.new("bad param", nil))
    described_class.new.perform

    transfer_key = "#{dedupe_key}:#{fingerprint_for(row.id)}:0:72850"
    expect($redis.get(transfer_key)).to eq("retryable") # parameters must survive a safe retry

    allow(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).and_call_original
    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).once

    described_class.new.perform
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id))
    $redis.del("#{RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)}:#{fingerprint_for(row.id)}:0:72850")
  end

  it "does not overfund when only one of two previously-funded rows reconciles, leaving the other still outstanding" do
    row_a = residue_row(-100_00)
    residue_row(-150_00)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)
    dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)

    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(hash_including(amount_cents: usd_for(250_00))).once
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

    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(hash_including(amount_cents: usd_for(300_00))).once
    described_class.new.perform

    # row_a reconciles; row_b (still funded) survives; a brand-new, unrelated row_c lands alongside it.
    row_a.mark_processing!
    row_a.mark_paid!
    residue_row(-50_00)

    # Only row_b's 200_00 credit should carry forward — the aggregate 300_00 must not swallow row_c's
    # new 50_00 shortfall (the exact "Aggregate credit suppresses new negative rows" scenario).
    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(hash_including(amount_cents: usd_for(50_00))).once
    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async).with(anything, anything, a_string_including("ESCALATE")).exactly(0).times
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id))
  end

  it "persists the transfer claim the instant Stripe accepts, before the funded-state write, so a crash in between can't be retried once the local TTL lapses" do
    row = residue_row(-728_50)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)
    dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)
    transfer_key = "#{dedupe_key}:#{fingerprint_for(row.id)}:0:72850"

    described_class.new.perform

    expect($redis.ttl(transfer_key)).to eq(-1) # persisted, not left on the 7-day TTL
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id))
    $redis.del("#{RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)}:#{fingerprint_for(row.id)}:0:72850")
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
    row = residue_row(-100_00)
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
    $redis.del("#{dedupe_key}:#{fingerprint_for(row.id)}:0:10000")
  end

  it "refreshes an account's funded-state TTL even when it falls outside the per-run processing cap" do
    row = residue_row(-100_00)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)
    dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)

    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(hash_including(amount_cents: usd_for(100_00))).once
    described_class.new.perform
    expect($redis.get(dedupe_key).to_i).to eq(100_00)
    $redis.expire(dedupe_key, 1.hour) # simulate the funded-state TTL nearly lapsing

    # Stub the scan so this account's candidate is pushed past MAX_TOPUPS_PER_RUN, exercising the
    # exact "outside the cap" path the finding describes.
    allow(AlertOnNegativeDestinationBalancesJob).to receive(:scan).and_wrap_original do |original|
      result = original.call
      filler = result[:payable].first.merge(merchant_account: merchant_account, full_total: 0, balance_ids: [])
      result[:payable] = [filler] * AutoTopUpNegativeDestinationBalancesJob::MAX_TOPUPS_PER_RUN + result[:payable]
      result
    end

    described_class.new.perform

    expect($redis.ttl(dedupe_key)).to be > 1.hour
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(dedupe_key)
    $redis.del("#{dedupe_key}:#{fingerprint_for(row.id)}:0:10000")
  end

  it "keeps a surviving row's funded-state TTL alive while its account is below minimum, off the payable scan entirely" do
    row = residue_row(-100_00)
    payable_balance = create(:balance, user: seller, merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id),
                                       date: in_cycle_date, amount_cents: 200_00, holding_amount_cents: 200_00)
    seller.reload
    Feature.activate(:auto_topup_negative_destination_balances)
    dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)

    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(hash_including(amount_cents: usd_for(100_00))).once
    described_class.new.perform
    expect($redis.get(dedupe_key).to_i).to eq(100_00)
    $redis.expire(dedupe_key, 1.hour)

    # The account drops below its payout minimum: `scan[:payable]` is empty, and this row's only
    # trace is `unreconciled_not_payable`. Without the off-scan refresh, `perform` would return
    # before touching the TTL at all (payable is empty) and it would lapse.
    payable_balance.update!(amount_cents: 0, holding_amount_cents: 0)
    seller.reload
    described_class.new.perform

    expect($redis.ttl(dedupe_key)).to be > 1.hour

    # Now a brand-new, independent row lands and the account is payable again. The surviving
    # 100_00 credit must still be recognized so only the new row's delta is funded.
    new_row = residue_row(-50_00)
    payable_balance.update!(amount_cents: 200_00, holding_amount_cents: 200_00)
    seller.reload
    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(hash_including(amount_cents: usd_for(50_00))).once

    described_class.new.perform
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(dedupe_key)
    $redis.del("#{dedupe_key}:#{fingerprint_for(row.id)}:0:10000")
    $redis.del("#{dedupe_key}:#{fingerprint_for(row.id, new_row&.id)}:10000:15000") if new_row
  end

  it "keeps a surviving funded row's TTL alive even when a positive row masks the account from the scan" do
    row = residue_row(-100_00)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)
    dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)

    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(hash_including(amount_cents: usd_for(100_00))).once
    described_class.new.perform
    expect($redis.get(dedupe_key).to_i).to eq(100_00)
    $redis.expire(dedupe_key, 1.hour)

    # The funded row still exists, but an offsetting positive row makes both account-level scan
    # windows non-negative. It will not appear in payable or unreconciled_not_payable, so only the
    # redis-key sweep can keep its funded credit from lapsing.
    residue_row(150_00)

    described_class.new.perform

    expect($redis.ttl(dedupe_key)).to be > 1.hour
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(dedupe_key)
    $redis.del("#{dedupe_key}:#{fingerprint_for(row.id)}:0:10000")
  end

  it "escalates instead of double-transferring when a second run acquires an expired account lock while the first is still mid-Stripe-call" do
    residue_row(-100_00)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)
    dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)

    # Simulate the first run: it claimed the account lock, marked the account unresolved (now
    # done BEFORE the Stripe call), and is still mid-flight when its lock TTL lapses.
    lock_key = "#{dedupe_key}:lock"
    $redis.set(lock_key, "expired-run-token", ex: 1)
    $redis.set("#{dedupe_key}:unresolved", 100_00)
    sleep 1.1

    expect(StripeTransferInternallyToCreator).not_to receive(:transfer_funds_to_account)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async).with(anything, anything, a_string_including("ambiguous Stripe outcome")).once
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(dedupe_key)
    $redis.del("#{dedupe_key}:unresolved")
    $redis.del("#{dedupe_key}:lock")
  end

  it "noops when a refund/credit nets the window's USD ledger negative between scan and the live re-read" do
    row = residue_row(-100_00)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)

    # After the scan already flagged this candidate, a refund lands: amount_cents (the USD ledger)
    # goes negative for the same row while holding_amount_cents stays negative too. resolve_entry's
    # own `next if set.sum(:amount_cents).negative?` guard caught this at scan time; a refund arriving
    # after the scan but before this account's turn must trip the same guard on the live re-read.
    allow(AlertOnNegativeDestinationBalancesJob).to receive(:scan).and_wrap_original do |original|
      result = original.call
      row.update!(amount_cents: -100_00)
      result
    end

    expect(StripeTransferInternallyToCreator).not_to receive(:transfer_funds_to_account)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to start_with("Topped up 0 of 1 candidates")
    end
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
  end

  it "escalates instead of resending when Stripe accepts the transfer but Redis persist keeps failing" do
    residue_row(-100_00)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)
    dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)

    allow(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account)
    # Simulates a Redis outage that outlives the accepted transfer: every `persist` call after
    # Stripe already accepted the money fails, so the durable dedupe write can never land.
    allow($redis).to receive(:persist).and_call_original
    allow($redis).to receive(:persist).with(a_string_matching(/:0:10000\z/)).and_raise(Redis::BaseConnectionError)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async).with(anything, anything, a_string_including("durable dedupe claim could not be confirmed")).once
    # The claim must still be held on its original TTL, not lost — a human has to confirm with
    # Stripe before either key can be cleared, so a later run doesn't resend the accepted transfer.
    expect($redis.get("#{dedupe_key}:unresolved")).to eq("10000")
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
    $redis.del(dedupe_key)
    $redis.del("#{dedupe_key}:unresolved")
  end

  it "sizes the USD transfer from the local hole: converted at the current rate, plus the buffer, rounded up to a whole cent" do
    residue_row(-101) # 101 / 2.0 = 50.5 → ×1.2 = 60.6 → 61
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)

    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(
      hash_including(currency: Currency::USD, amount_cents: 61, metadata: hash_including(destination_hole_cents: 101))
    )

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, subject, message|
      expect(subject).to eq("Negative destination balance top-ups")
      expect(message).to include("FUNDED #{seller.email} — 101 php cents hole → 61 USD cents sent")
      expect(message).to include("20% buffer")
    end
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
  end

  it "sizes a single-unit destination currency through get_usd_cents, so a whole-unit hole is not treated as hundredths" do
    merchant_account.update!(currency: "jpy", country: "JP")
    create(:balance, user: seller, merchant_account:, date: in_cycle_date,
                     amount_cents: 0, holding_currency: "jpy", holding_amount_cents: -1_000)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)

    # ¥1,000 (single_unit) / 100 = 1,000 US cents → ×1.2 = 1,200; as hundredths it would be 12.
    expect(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).with(
      hash_including(currency: Currency::USD, amount_cents: 1_200)
    )

    described_class.new.perform
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
  end

  it "escalates without taking a claim when no exchange rate is available, instead of sending zero or a local-currency amount" do
    residue_row(-728_50)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)
    allow_any_instance_of(described_class).to receive(:get_rate).and_return(nil)
    dedupe_key = RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id)

    expect(StripeTransferInternallyToCreator).not_to receive(:transfer_funds_to_account)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to include("ESCALATE #{seller.email} — no usable USD exchange rate for php")
    end
    expect($redis.get(dedupe_key)).to be_nil
    expect($redis.keys("#{dedupe_key}:*")).to be_empty
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
  end

  it "reports a rate-lookup failure as an error instead of misreading it as a missing rate" do
    residue_row(-728_50)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)
    allow_any_instance_of(described_class).to receive(:get_rate).and_raise(Redis::CannotConnectError)

    expect(StripeTransferInternallyToCreator).not_to receive(:transfer_funds_to_account)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to include("ERROR #{seller.email} — Redis::CannotConnectError")
      expect(message).not_to include("no usable USD exchange rate")
    end
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
  end

  it "escalates on a dry run too when no exchange rate is available, so the preview matches live readiness" do
    residue_row(-728_50)
    make_payable
    allow_any_instance_of(described_class).to receive(:get_rate).and_return(nil)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, message|
      expect(message).to include("would top up 0 of 1 candidates")
      expect(message).to include("ESCALATE #{seller.email} — no usable USD exchange rate for php")
      expect(message).not_to include("nil USD cents")
    end
  end

  it "flags a live run that processed payable candidates and funded none, in the subject and the body" do
    residue_row(-728_50)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)

    allow(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account)
      .and_raise(Stripe::InvalidRequestError.new("You have insufficient funds in your Stripe account.", nil))

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |room, subject, message|
      expect(room).to eq("payouts")
      expect(subject).to eq("ALL FAILED: Negative destination balance top-ups")
      expect(message).to start_with("ALL FAILED: a live run processed 1 payable candidates and topped up none — 0 withheld, 1 errored.")
      expect(message).to include("Topped up 0 of 1 candidates")
    end
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
  end

  it "does not raise the all-failed flag on a dry run, which never tops anything up by design" do
    residue_row(-728_50)
    make_payable

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, subject, message|
      expect(subject).to eq("Negative destination balance top-ups")
      expect(message).not_to include("ALL FAILED")
      expect(message).to include("WOULD FUND #{seller.email} — 72850 php cents hole → #{usd_for(728_50)} USD cents sent")
    end
  end
  context "with an immutable transfer request" do
    let!(:row) { residue_row(-100_00) }
    let(:dedupe_key) { RedisKey.auto_topup_negative_destination_balance_last_amount(merchant_account.id) }
    let(:transfer_key) { "#{dedupe_key}:#{fingerprint_for(row.id)}:0:10000" }
    let(:request_key) { "#{transfer_key}:request" }

    before do
      make_payable
      Feature.activate(:auto_topup_negative_destination_balances)
    end

    after do
      Feature.deactivate(:auto_topup_negative_destination_balances)
    end

    ["4.0", nil].each do |later_rate|
      it "reuses every request parameter after a rejection when the later FX rate is #{later_rate.inspect}" do
        requests = []
        allow(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account) do |**request|
          requests << request
          raise Stripe::RateLimitError, "rate limited" if requests.one?
        end

        described_class.new.perform
        original_destination = merchant_account.charge_processor_merchant_id
        merchant_account.update!(charge_processor_merchant_id: "acct_changed", currency: "eur")
        allow_any_instance_of(described_class).to receive(:get_rate).and_return(later_rate)

        described_class.new.perform

        expect(requests.size).to eq(2)
        expect(requests.last).to eq(requests.first)
        expect(JSON.parse($redis.get(request_key), symbolize_names: true)).to eq(requests.first)
        expect($redis.ttl(request_key)).to eq(-1)
        expect(requests.last).to include(stripe_account_id: original_destination, currency: Currency::USD, amount_cents: usd_for(100_00))
        expect(requests.last[:metadata]).to include(destination_currency: "php", destination_hole_cents: 100_00)
        expect($redis.get(dedupe_key)).to eq("10000:#{row.id}")
        expect($redis.get("#{dedupe_key}:unresolved")).to be_nil
      end
    end

    it "retains the same request and error when Stripe replays an executed rejection" do
      requests = []
      allow(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account) do |**request|
        requests << request
        raise Stripe::InvalidRequestError.new("cached insufficient funds", nil, http_status: 400, http_headers: { "idempotent-replayed" => "true" })
      end
      described_class.new.perform
      allow_any_instance_of(described_class).to receive(:get_rate).and_return("4.0")
      described_class.new.perform

      expect(requests.size).to eq(2)
      expect(requests.last).to eq(requests.first)
      expect($redis.get(transfer_key)).to eq("retryable")
      expect($redis.ttl(transfer_key)).to eq(-1)
      expect($redis.get(dedupe_key)).to be_nil
      expect(InternalNotificationWorker).to have_received(:perform_async).with(anything, /ALL FAILED/, /cached insufficient funds/).twice
    end

    it "retains parameters after the old claim TTL and Stripe idempotency window have elapsed" do
      requests = []
      allow(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account) do |**request|
        requests << request
        raise Stripe::RateLimitError, "rate limited" if requests.one?
      end
      described_class.new.perform
      travel 8.days do
        allow_any_instance_of(described_class).to receive(:get_rate).and_return(nil)
        described_class.new.perform
      end
      expect(requests.size).to eq(2)
      expect(requests.last).to eq(requests.first)
      expect($redis.ttl(request_key)).to eq(-1)
    end

    [nil, "{", "{}", '{"amount_cents":0}'].each do |saved|
      it "withholds a retry with missing or corrupt parameters #{saved.inspect}" do
        allow(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).and_raise(Stripe::RateLimitError, "rate limited")
        described_class.new.perform
        saved ? $redis.set(request_key, saved) : $redis.del(request_key)
        expect(StripeTransferInternallyToCreator).not_to receive(:transfer_funds_to_account)
        described_class.new.perform
        expect($redis.get(dedupe_key)).to be_nil
        expect(InternalNotificationWorker).to have_received(:perform_async).with(anything, anything, /ESCALATE/).once
      end
    end

    it "holds an existing legacy claim even without saved parameters or a current rate" do
      $redis.set(transfer_key, 1)
      allow_any_instance_of(described_class).to receive(:get_rate).and_return(nil)
      expect(StripeTransferInternallyToCreator).not_to receive(:transfer_funds_to_account)
      described_class.new.perform
      expect($redis.get(transfer_key)).to eq("1")
      expect($redis.get(request_key)).to be_nil
      expect(InternalNotificationWorker).to have_received(:perform_async).with(anything, anything, /already in flight/)
    end

    [false, :raise].each do |failure|
      it "sends nothing if persisting the request fails with #{failure}" do
        allow($redis).to receive(:set).and_call_original
        write = allow($redis).to receive(:set).with(request_key, anything, nx: true)
        failure == :raise ? write.and_raise(Redis::BaseConnectionError) : write.and_return(false)
        expect(StripeTransferInternallyToCreator).not_to receive(:transfer_funds_to_account)
        described_class.new.perform
        expect($redis.get(dedupe_key)).to be_nil
        expect($redis.get("#{dedupe_key}:lock")).to be_nil
      end
    end

    it "reuses parameters when Redis saved them but the write acknowledgement was lost" do
      allow(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account)
      allow($redis).to receive(:set).and_call_original
      allow($redis).to receive(:set).with(request_key, anything, nx: true).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs)
        raise Redis::BaseConnectionError, "lost write acknowledgement"
      end
      described_class.new.perform
      expect(StripeTransferInternallyToCreator).not_to have_received(:transfer_funds_to_account)
      saved_request = $redis.get(request_key)
      expect(saved_request).to be_present

      allow($redis).to receive(:set).with(request_key, anything, nx: true).and_call_original
      allow_any_instance_of(described_class).to receive(:get_rate).and_return(nil)
      described_class.new.perform

      expect(StripeTransferInternallyToCreator).to have_received(:transfer_funds_to_account).with(**JSON.parse(saved_request, symbolize_names: true)).once
    end

    ["marker false", "marker raise", "marker lost acknowledgement", "cleanup raise", "cleanup lost acknowledgement", "marker and persist raise"].each do |failure|
      it "continues later candidates and reports rejection bookkeeping failure for #{failure}" do
        other_account = create(:merchant_account, user: seller, charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                                  charge_processor_merchant_id: "acct_later", currency: Currency::PHP, country: "PH")
        create(:balance, user: seller, merchant_account: other_account, date: in_cycle_date,
                         amount_cents: 0, holding_currency: Currency::PHP, holding_amount_cents: -50_00)
        requests = []
        allow(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account) do |**request|
          requests << request
          if request[:stripe_account_id] == merchant_account.charge_processor_merchant_id
            raise Stripe::RateLimitError, "rejected request" if failure == "marker false"

            raise Stripe::InvalidRequestError.new("rejected request", nil)
          end
        end
        allow($redis).to receive(:set).and_call_original
        allow($redis).to receive(:del).and_call_original
        operation = failure.start_with?("marker") ? :set : :del
        args = operation == :set ? [transfer_key, "retryable"] : ["#{dedupe_key}:unresolved"]
        allow($redis).to receive(operation).with(*args).and_wrap_original do |original, *arguments|
          if failure == "marker false"
            false
          else
            original.call(*arguments) if failure.include?("lost acknowledgement")
            raise Redis::BaseConnectionError, "bookkeeping unavailable"
          end
        end
        if failure == "marker and persist raise"
          allow($redis).to receive(:persist).and_call_original
          allow($redis).to receive(:persist).with(transfer_key).and_raise(Redis::BaseConnectionError)
        end

        described_class.new.perform

        expect(requests.map { _1[:stripe_account_id] }).to eq([merchant_account.charge_processor_merchant_id, "acct_later"])
        expect(JSON.parse($redis.get(request_key), symbolize_names: true)).to eq(requests.first)
        expect($redis.ttl(request_key)).to eq(-1)
        expect($redis.get(dedupe_key)).to be_nil
        expect($redis.get("#{dedupe_key}:lock")).to be_nil
        expect(InternalNotificationWorker).to have_received(:perform_async).with(
          "payouts", "Negative destination balance top-ups",
          a_string_including("Topped up 1 of 2 candidates", "rejected request", "rejection bookkeeping failed", "FUNDED")
        ).once

        if failure == "cleanup lost acknowledgement"
          # The deletion completed after a known rejection; only the saved request may retry.
          expect($redis.get("#{dedupe_key}:unresolved")).to be_nil
          expect($redis.get(transfer_key)).to eq("retryable")
          expect($redis.ttl(transfer_key)).to eq(-1)
          allow($redis).to receive(:del).with("#{dedupe_key}:unresolved").and_call_original
          allow_any_instance_of(described_class).to receive(:get_rate).and_return(nil)
          described_class.new.perform
          expect(requests.size).to eq(3)
          expect(requests.last).to eq(requests.first)
        else
          expect($redis.get("#{dedupe_key}:unresolved")).to eq("10000")
          expect($redis.ttl("#{dedupe_key}:unresolved")).to eq(-1)
          expect($redis.ttl(transfer_key)).to eq(-1) unless failure == "marker and persist raise"
          saved_request = $redis.get(request_key)
          residue_row(-25_00)
          described_class.new.perform
          expect(requests.size).to eq(2)
          expect($redis.get(request_key)).to eq(saved_request)
        end
      end
    end

    it "treats a cached success as funding and holds it through a failure to record ledger credit" do
      allow(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account) do |**request|
        expect($redis.get(request_key)).to eq(request.to_json)
        Stripe::Transfer.construct_from(id: "tr_cached_success", amount: usd_for(100_00), currency: "usd")
      end
      allow($redis).to receive(:set).and_call_original
      allow($redis).to receive(:set).with(dedupe_key, anything, ex: described_class::DEDUPE_TTL).and_raise(Redis::BaseConnectionError)
      described_class.new.perform
      expect($redis.ttl(transfer_key)).to eq(-1)
      expect($redis.get("#{dedupe_key}:unresolved")).to eq("10000")
      residue_row(-50_00)
      allow_any_instance_of(described_class).to receive(:get_rate).and_return(nil)
      described_class.new.perform
      expect(StripeTransferInternallyToCreator).to have_received(:transfer_funds_to_account).once
    end

    it "keeps cached server errors unresolved even after the gap grows and the rate changes" do
      allow(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account) do |**request|
        expect($redis.get(request_key)).to eq(request.to_json)
        raise Stripe::APIError.new("cached server error", http_status: 500, http_headers: { "idempotent-replayed" => "true" })
      end
      described_class.new.perform
      residue_row(-50_00)
      allow_any_instance_of(described_class).to receive(:get_rate).and_return("4.0")
      described_class.new.perform
      expect(StripeTransferInternallyToCreator).to have_received(:transfer_funds_to_account).once
      expect($redis.ttl(transfer_key)).to eq(-1)
      expect($redis.get("#{dedupe_key}:unresolved")).to eq("10000")
    end
  end

  it "does not label funded entries awaiting reconciliation as all failed" do
    residue_row(-100_00)
    make_payable
    Feature.activate(:auto_topup_negative_destination_balances)
    allow(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account)
    described_class.new.perform
    described_class.new.perform

    expect(StripeTransferInternallyToCreator).to have_received(:transfer_funds_to_account).once
    expect(InternalNotificationWorker).to have_received(:perform_async).with(anything, "Negative destination balance top-ups", /already topped up/).once
    expect(InternalNotificationWorker).not_to have_received(:perform_async).with(anything, /ALL FAILED/, anything)
  ensure
    Feature.deactivate(:auto_topup_negative_destination_balances)
  end

  [false, true].each do |retired|
    it "still flags #{retired ? "withheld funding" : "transfer errors"} alongside funded entries awaiting reconciliation" do
      residue_row(-100_00)
      make_payable
      Feature.activate(:auto_topup_negative_destination_balances)
      allow(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account)
      described_class.new.perform
      other_account = create(:merchant_account, user: seller, charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                                charge_processor_merchant_id: "acct_other", currency: Currency::PHP, country: "PH")
      create(:balance, user: seller, merchant_account: other_account, date: in_cycle_date,
                       amount_cents: 0, holding_currency: Currency::PHP, holding_amount_cents: -50_00)
      other_account.mark_deleted! if retired
      allow(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account).and_raise(Stripe::RateLimitError, "rate limited")
      described_class.new.perform

      counts = retired ? "1 withheld, 0 errored" : "0 withheld, 1 errored"
      reason = retired ? "RETIRED" : "rate limited"
      expect(InternalNotificationWorker).to have_received(:perform_async).with(anything, /ALL FAILED/, a_string_including(counts, "already topped up", reason)).once
    ensure
      Feature.deactivate(:auto_topup_negative_destination_balances)
    end
  end
end
