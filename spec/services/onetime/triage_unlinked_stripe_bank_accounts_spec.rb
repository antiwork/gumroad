# frozen_string_literal: true

require "spec_helper"

describe Onetime::TriageUnlinkedStripeBankAccounts do
  let(:skip_reason) { StripePayoutProcessor::UNLINKED_BANK_ACCOUNT_SKIP_REASON }

  def seller_with_unlinked_row(bank_account_factory: :ach_account, user: create(:compliant_user), merchant_account: true)
    create(:user_compliance_info, user:) if user.alive_user_compliance_info.nil?
    stripe_account = create(:merchant_account, user:) if merchant_account
    bank_account = travel_to(2.days.ago) { create(bank_account_factory, user:) }
    create(:balance, user:, merchant_account: stripe_account || MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: 150_00, date: 2.weeks.ago.to_date)
    user.add_payout_note(content: "Payout on September 18, 2026 #{skip_reason}")
    [user, bank_account]
  end

  def pause_for_chargeback_rate!(user)
    user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
    user.comments.create!(
      content: "Payouts automatically paused due to chargeback rate (4.0%).",
      comment_type: Comment::COMMENT_TYPE_ON_PROBATION,
      author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:high_chargeback_rate]
    )
  end

  def count_queries(&block)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:cached] || %w[SCHEMA TRANSACTION].include?(payload[:name]) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    count
  end

  def triage(*bank_accounts, **options)
    ids = bank_accounts.map(&:id)
    described_class.process(start_id: ids.min, end_id: ids.max, **options)
  end

  def disposition_for(bank_account, result = triage(bank_account))
    result[:dispositions].dig(bank_account.id, :disposition)
  end

  before do
    Sidekiq::Worker.clear_all
    allow(Stripe::Account).to receive(:retrieve)
    allow(Stripe::Account).to receive(:update)
    allow(Stripe::Account).to receive(:create)
    allow(Stripe::Account).to receive(:delete)
    allow(Stripe::Account).to receive(:list_external_accounts)
    allow(StripeMerchantAccountManager).to receive(:update_bank_account)
    allow(StripeMerchantAccountManager).to receive(:create_account)
  end

  it "reports a generic skip on an unlinked row as provider-unverified, keyed by bank row id" do
    user, bank_account = seller_with_unlinked_row

    result = triage(bank_account)

    expect(result[:dispositions].fetch(bank_account.id).except(:payout_window_end_date)).to eq(
      disposition: :provider_identity_unverified,
      user_id: user.id,
      bank_account_type: "AchAccount",
      unpaid_usd_ledger_cents: 150_00,
      payout_window_usd_ledger_cents: 150_00,
      generic_skip_note_count: 1,
      latest_generic_skip_at: user.comments.last.created_at,
      provider_identity: "unverified"
    )
    expect(result[:dispositions].dig(bank_account.id, :payout_window_end_date)).to be_a(Date)
    expect(result[:next_start_id]).to eq(bank_account.id + 1)
    expect(result[:done]).to be(true)
  end

  it "counts only generic skips written since this bank row was created" do
    user, bank_account = seller_with_unlinked_row
    user.comments.update_all(created_at: 1.week.ago)
    current_note = user.add_payout_note(content: "Payout on September 25, 2026 #{skip_reason}")

    result = triage(bank_account)[:dispositions].fetch(bank_account.id)
    expect(result[:generic_skip_note_count]).to eq(1)
    expect(result[:latest_generic_skip_at]).to eq(current_note.created_at)
  end

  it "discovers the skip note the Stripe payout processor writes" do
    user, bank_account = seller_with_unlinked_row
    user.comments.each(&:mark_deleted!)

    expect(StripePayoutProcessor.is_user_payable(user, 150_00, add_comment: true)).to be(false)

    expect(disposition_for(bank_account)).to eq(:provider_identity_unverified)
  end

  it "reports the row once however many generic skips it has, and a repeat scan writes nothing" do
    user, bank_account = seller_with_unlinked_row
    user.add_payout_note(content: "Payout on September 25, 2026 #{skip_reason}")
    other_note = user.add_payout_note(content: "Stripe bank sync failed: unknown — synthetic", seller_visible: false,
                                      json_data: { "abandoned_at" => 1.week.ago.iso8601, "retry_count" => 8 })
    Sidekiq::Worker.clear_all
    bank_attributes = bank_account.reload.attributes
    notes_before = user.comments.map { _1.attributes.except("json_data").merge("json_data" => _1.json_data.dup) }

    first = triage(bank_account)
    second = triage(bank_account)

    expect(first).to eq(second)
    expect(first[:dispositions].keys).to eq([bank_account.id])
    expect(first[:dispositions][bank_account.id][:generic_skip_note_count]).to eq(2)
    expect(user.comments.reload.map { _1.attributes.except("json_data").merge("json_data" => _1.json_data) }).to eq(notes_before)
    expect(other_note.reload.json_data).to include("abandoned_at", "retry_count" => 8)
    expect(bank_account.reload.attributes).to eq(bank_attributes)
    expect(Payment.count).to eq(0)
    expect(user.balances.pluck(:state)).to eq(["unpaid"])
    expect(Sidekiq::Worker.jobs.size).to eq(0)
    expect(RetryStripeRejectedPayoutSetupForSellerJob.jobs.size).to eq(0)
  end

  it "never calls Stripe or the bank-sync paths" do
    _user, bank_account = seller_with_unlinked_row

    triage(bank_account)

    %i[retrieve update create delete list_external_accounts].each do |method|
      expect(Stripe::Account).not_to have_received(method)
    end
    expect(StripeMerchantAccountManager).not_to have_received(:update_bank_account)
    expect(StripeMerchantAccountManager).not_to have_received(:create_account)
  end

  describe "discovery" do
    it "ignores linked, deleted, zero-balance and non-generic-skip rows" do
      _, linked = seller_with_unlinked_row
      linked.update_column(:stripe_bank_account_id, "ba_synthetic_linked")
      _, deleted = seller_with_unlinked_row
      deleted.mark_deleted!
      zero_user, zero_balance = seller_with_unlinked_row
      zero_user.balances.update_all(state: "paid")
      other_user, other_skip = seller_with_unlinked_row
      other_user.comments.update_all(content: "Payout on September 18, 2026 was skipped because there was already a payout in processing.")
      dead_note_user, dead_note = seller_with_unlinked_row
      dead_note_user.comments.each(&:mark_deleted!)

      result = triage(linked, deleted, zero_balance, other_skip, dead_note)

      expect(result[:dispositions]).to eq({})
    end

    it "ignores a generic skip written before the row existed" do
      user, bank_account = seller_with_unlinked_row
      user.comments.update_all(created_at: 1.week.ago)

      expect(triage(bank_account)[:dispositions]).to eq({})
    end

    it "ignores a replaced row and its linked replacement" do
      user, old_row = seller_with_unlinked_row
      old_row.mark_deleted!
      new_row = create(:ach_account, user:, stripe_bank_account_id: "ba_synthetic_new")

      expect(triage(old_row, new_row)[:dispositions]).to eq({})
    end

    it "walks primary-key windows and never past MAX_ID_SPAN" do
      stub_const("#{described_class}::MAX_ID_SPAN", 2)
      _, first = seller_with_unlinked_row
      _, second = seller_with_unlinked_row
      _, beyond = seller_with_unlinked_row
      beyond.update_column(:id, second.id + 10)

      result = described_class.process(start_id: first.id, end_id: beyond.id, batch_size: 1)

      expect(result[:dispositions].keys).to contain_exactly(first.id, second.id)
      expect(result[:next_start_id]).to eq(first.id + 2)
      expect(result[:done]).to be(false)
      expect(described_class.process(start_id: beyond.id)[:done]).to be(true)
      expect(described_class.process(start_id: beyond.id + 1)).to eq(
        dispositions: {}, next_start_id: beyond.id + 1, done: true
      )
    end

    it "stops at MAX_CLASSIFIED_ROWS and resumes after the last classified row" do
      stub_const("#{described_class}::MAX_CLASSIFIED_ROWS", 2)
      rows = Array.new(3) { seller_with_unlinked_row.last }

      first = triage(*rows)
      expect(first[:dispositions].keys).to eq(rows.first(2).map(&:id))
      expect(first[:next_start_id]).to eq(rows.second.id + 1)
      expect(first[:done]).to be(false)
      expect(described_class.process(start_id: first[:next_start_id])[:dispositions].keys).to eq([rows.third.id])

      by_window = triage(*rows, batch_size: 1)
      expect(by_window[:dispositions].keys).to eq(rows.first(2).map(&:id))
      expect(by_window[:next_start_id]).to eq(rows.third.id)
    end

    it "rejects invalid or unbounded input" do
      expect { described_class.process(start_id: 0) }.to raise_error(ArgumentError)
      expect { described_class.process(start_id: "1") }.to raise_error(ArgumentError)
      expect { described_class.process(batch_size: 0) }.to raise_error(ArgumentError)
      expect { described_class.process(batch_size: described_class::BATCH_SIZE + 1) }.to raise_error(ArgumentError)
      expect { described_class.process(start_id: 10, end_id: 9) }.to raise_error(ArgumentError)
      expect { described_class.process(end_id: "100") }.to raise_error(ArgumentError)
    end
  end

  describe "unpaid balances" do
    def add_balance(user, merchant_account:, amount_cents:, holding_currency: Currency::USD, holding_amount_cents: amount_cents, date: 2.weeks.ago.to_date)
      create(:balance, user:, merchant_account:, amount_cents:, holding_currency:, holding_amount_cents:, date:)
    end

    it "does not treat a future balance as payable in the next standard cycle" do
      user, bank_account = seller_with_unlinked_row
      user.balances.update_all(amount_cents: 50_00)
      add_balance(user, merchant_account: user.stripe_account, amount_cents: 150_00,
                        date: User::PayoutSchedule.next_scheduled_payout_date + 7)

      result = triage(bank_account)[:dispositions].fetch(bank_account.id)
      expect(result[:unpaid_usd_ledger_cents]).to eq(200_00)
      expect(result[:payout_window_usd_ledger_cents]).to eq(50_00)
      expect(result[:disposition]).to eq(:below_payout_minimum)
    end

    it "keeps today's US rail window until the 10:00 UTC payout run starts" do
      travel_to(Time.utc(2026, 9, 24, 9))
      user, bank_account = seller_with_unlinked_row
      user.balances.update_all(amount_cents: 50_00)
      add_balance(user, merchant_account: user.stripe_account, amount_cents: 80_00, date: Date.new(2026, 9, 19))

      result = triage(bank_account)[:dispositions].fetch(bank_account.id)
      expect(result[:payout_window_end_date]).to eq(Date.new(2026, 9, 18))
      expect(result[:payout_window_usd_ledger_cents]).to eq(50_00)
      expect(result[:disposition]).to eq(:below_payout_minimum)
    ensure
      travel_back
    end

    it "moves past this week's US rail after it has run" do
      travel_to(Time.utc(2026, 9, 25, 12))
      user, bank_account = seller_with_unlinked_row
      user.balances.update_all(amount_cents: 50_00)
      add_balance(user, merchant_account: user.stripe_account, amount_cents: 80_00, date: Date.new(2026, 9, 19))

      result = triage(bank_account)[:dispositions].fetch(bank_account.id)
      expect(result[:payout_window_end_date]).to eq(Date.new(2026, 9, 25))
      expect(result[:payout_window_usd_ledger_cents]).to eq(130_00)
      expect(result[:disposition]).to eq(:provider_identity_unverified)
    ensure
      travel_back
    end

    it "uses each bank rail's next run rather than a Friday fallback" do
      travel_to(Time.utc(2026, 9, 23, 12))
      _uk_user, uk_row = seller_with_unlinked_row(bank_account_factory: :uk_bank_account)
      _us_user, us_row = seller_with_unlinked_row

      result = triage(uk_row, us_row)[:dispositions]
      expect(result.dig(uk_row.id, :payout_window_end_date)).to eq(Date.new(2026, 9, 25))
      expect(result.dig(us_row.id, :payout_window_end_date)).to eq(Date.new(2026, 9, 18))
    ensure
      travel_back
    end

    it "uses the weekly fallback for a daily-frequency seller on an unlinked bank row" do
      user, bank_account = seller_with_unlinked_row
      user.update!(payout_frequency: User::PayoutSchedule::DAILY)

      expect(disposition_for(bank_account)).to eq(:provider_identity_unverified)
    end

    it "requires manual schedule review for a monthly seller" do
      user, bank_account = seller_with_unlinked_row
      user.update!(payout_frequency: User::PayoutSchedule::MONTHLY)

      result = triage(bank_account)[:dispositions].fetch(bank_account.id)
      expect(result[:disposition]).to eq(:payout_schedule_requires_review)
      expect(result[:payout_window_end_date]).to be_nil
      expect(result[:payout_window_usd_ledger_cents]).to be_nil
    end

    it "keeps an unsupported legacy bank rail out of the Friday Connect window" do
      _user, bank_account = seller_with_unlinked_row
      bank_account.update_column(:type, "ZenginAccount")

      result = triage(bank_account)[:dispositions].fetch(bank_account.id)
      expect(result[:disposition]).to eq(:no_payout_rail)
      expect(result[:payout_window_end_date]).to be_nil
      expect(result[:payout_window_usd_ledger_cents]).to be_nil
    end

    it "does not preload an unbounded balance history" do
      stub_const("#{described_class}::MAX_UNPAID_BALANCES_PER_USER", 2)
      user, bank_account = seller_with_unlinked_row
      2.times { add_balance(user, merchant_account: user.stripe_account, amount_cents: 20_00) }

      result = triage(bank_account)[:dispositions].fetch(bank_account.id)
      expect(result[:disposition]).to eq(:balance_history_requires_review)
      expect(result[:unpaid_usd_ledger_cents]).to eq(190_00)
      expect(result[:payout_window_usd_ledger_cents]).to be_nil
    end

    it "reports the USD ledger total, not a sum of holding amounts in different currencies" do
      user, bank_account = seller_with_unlinked_row
      add_balance(user, merchant_account: user.stripe_account, amount_cents: 20_00, holding_currency: "cad", holding_amount_cents: 27_00)

      result = triage(bank_account)[:dispositions].fetch(bank_account.id)
      expect(result[:disposition]).to eq(:provider_identity_unverified)
      expect(result[:unpaid_usd_ledger_cents]).to eq(170_00)
    end

    it "flags a net-positive ledger whose account/currency payout group is negative" do
      user, bank_account = seller_with_unlinked_row
      add_balance(user, merchant_account: user.stripe_account, amount_cents: -50_00, holding_currency: "cad", holding_amount_cents: -68_00)

      result = triage(bank_account)[:dispositions].fetch(bank_account.id)
      expect(result[:unpaid_usd_ledger_cents]).to eq(100_00)
      expect(result[:disposition]).to eq(:negative_balance_group)
    end

    it "flags a negative balance left on a replaced Stripe account" do
      user, bank_account = seller_with_unlinked_row
      retired_account = create(:merchant_account, user:, deleted_at: Time.current)
      add_balance(user, merchant_account: retired_account, amount_cents: -10_00)

      expect(disposition_for(bank_account)).to eq(:negative_balance_group)
    end

    it "nets a Gumroad-held debt into the Stripe account group it pays out through" do
      user, bank_account = seller_with_unlinked_row
      add_balance(user, merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: -20_00)

      expect(disposition_for(bank_account)).to eq(:provider_identity_unverified)
    end
  end

  describe "query cost" do
    # Generous ceilings: the point is that cost is per window and per classified row, never per scanned id.
    let(:window_query_ceiling) { 25 }
    let(:row_query_ceiling) { 40 }

    it "costs a constant number of queries per classified row" do
      rows = Array.new(5) { seller_with_unlinked_row.last }
      triage(rows.first)

      one_row = count_queries { triage(rows.first) }
      five_rows = count_queries { triage(*rows) }
      per_row = (five_rows - one_row) / 4.0

      puts "QUERIES one=#{one_row} five=#{five_rows} per_row=#{per_row}"
      expect(per_row).to be <= row_query_ceiling
      expect(one_row - per_row).to be <= window_query_ceiling
      worst_case = (described_class::MAX_ID_SPAN / described_class::BATCH_SIZE) * window_query_ceiling +
                   described_class::MAX_CLASSIFIED_ROWS * row_query_ceiling
      expect(worst_case).to be < 15_000
    end

    it "does not classify rows past the cap, however dense the window" do
      stub_const("#{described_class}::MAX_CLASSIFIED_ROWS", 2)
      rows = Array.new(6) { seller_with_unlinked_row.last }
      triage(*rows.first(2))

      at_cap = count_queries { triage(*rows.first(2)) }
      dense = count_queries { triage(*rows) }

      puts "QUERIES at_cap=#{at_cap} dense=#{dense}"
      expect(dense).to be <= at_cap
    end

    it "costs a constant number of queries per window with no candidates" do
      rows = Array.new(4) { seller_with_unlinked_row.last }
      rows.each { _1.user.balances.update_all(state: "paid") }

      per_window = count_queries { triage(*rows, batch_size: 1) } / rows.size.to_f

      puts "QUERIES per_window=#{per_window}"
      expect(per_window).to be <= 3
    end
  end

  describe "fail-closed dispositions" do
    it "flags a row linked by a concurrent sync mid-scan" do
      _user, bank_account = seller_with_unlinked_row
      allow_any_instance_of(User).to receive(:compliant?).and_wrap_original do |original|
        BankAccount.where(id: bank_account.id).update_all(stripe_bank_account_id: "ba_synthetic_concurrent")
        original.call
      end

      expect(disposition_for(bank_account)).to eq(:bank_row_changed_during_scan)
    end

    it "flags a row deleted mid-scan" do
      _user, bank_account = seller_with_unlinked_row
      allow_any_instance_of(User).to receive(:compliant?).and_wrap_original do |original|
        BankAccount.where(id: bank_account.id).update_all(deleted_at: Time.current)
        original.call
      end

      expect(disposition_for(bank_account)).to eq(:bank_row_changed_during_scan)
    end

    it "flags another live bank row created during classification" do
      user, bank_account = seller_with_unlinked_row
      allow_any_instance_of(User).to receive(:compliant?).and_wrap_original do |original|
        create(:ach_account, user:)
        original.call
      end

      expect(disposition_for(bank_account)).to eq(:bank_row_changed_during_scan)
    end

    it "flags a seller with more than one alive bank row" do
      user, bank_account = seller_with_unlinked_row
      create(:ach_account, user:)

      expect(disposition_for(bank_account)).to eq(:ambiguous_bank_rows)
    end

    it "flags a minor who lacks the guardian needed for payouts" do
      _user, bank_account = seller_with_unlinked_row
      allow_any_instance_of(UserComplianceInfo).to receive(:under_legal_guardian_age?).and_return(true)
      allow_any_instance_of(UserComplianceInfo).to receive(:legal_guardian_requirement_met?).and_return(false)

      expect(disposition_for(bank_account)).to eq(:guardian_required)
    end

    it "flags a seller with a processing payment, even a stuck one" do
      user, bank_account = seller_with_unlinked_row
      create(:payment, user:, state: "processing", created_at: 1.month.ago)

      expect(disposition_for(bank_account)).to eq(:processing_payment)
    end

    it "flags a creating payout before the Stripe transfer finishes" do
      user, bank_account = seller_with_unlinked_row
      create(:payment, user:, state: Payment::CREATING)

      expect(disposition_for(bank_account)).to eq(:processing_payment)
    end

    it "flags claimed balances even if the payment row is absent" do
      user, bank_account = seller_with_unlinked_row
      create(:balance, user:, state: "processing", amount_cents: 20_00)

      expect(disposition_for(bank_account)).to eq(:processing_payment)
    end

    it "flags a seller with no alive Stripe merchant account" do
      _user, bank_account = seller_with_unlinked_row(merchant_account: false)

      expect(disposition_for(bank_account)).to eq(:no_merchant_account)
    end

    it "flags a seller whose Stripe merchant account is ambiguous" do
      user, bank_account = seller_with_unlinked_row
      create(:merchant_account, user:)

      expect(disposition_for(bank_account)).to eq(:ambiguous_merchant_account)
    end

    it "flags a merchant account with no Stripe account id" do
      user, bank_account = seller_with_unlinked_row
      user.merchant_accounts.update_all(charge_processor_merchant_id: nil)

      expect(disposition_for(bank_account)).to eq(:ambiguous_merchant_account)
    end

    it "flags an IBAN row, which has no routing number to match on" do
      _user, bank_account = seller_with_unlinked_row(bank_account_factory: :european_bank_account)

      expect(disposition_for(bank_account)).to eq(:missing_routing)
    end

    it "flags a row with a blank routing number" do
      _user, bank_account = seller_with_unlinked_row
      bank_account.update_column(:bank_number, nil)

      expect(disposition_for(bank_account)).to eq(:missing_routing)
    end

    it "flags a seller under a risk hold" do
      user, bank_account = seller_with_unlinked_row
      user.update_column(:user_risk_state, "flagged_for_fraud")

      expect(disposition_for(bank_account)).to eq(:risk_hold)
    end

    it "flags a stale skip note once the unpaid ledger is below the standard minimum" do
      user, bank_account = seller_with_unlinked_row
      user.balances.update_all(amount_cents: 42_00, holding_amount_cents: 42_00)

      expect(disposition_for(bank_account)).to eq(:below_payout_minimum)
    end

    it "flags a chargeback reserve separately from an ordinary pause" do
      user, bank_account = seller_with_unlinked_row
      pause_for_chargeback_rate!(user)

      expect(disposition_for(bank_account)).to eq(:chargeback_reserve_active)
    end

    it "does not treat a larger balance as proof that a reserve is cleared" do
      user, bank_account = seller_with_unlinked_row
      3.times { |days| create(:balance, user:, merchant_account: user.stripe_account, amount_cents: 150_00, date: days.days.ago) }
      pause_for_chargeback_rate!(user)

      expect(disposition_for(bank_account)).to eq(:chargeback_reserve_active)
    end

    it "flags a seller with paused payouts" do
      user, bank_account = seller_with_unlinked_row
      user.update!(payouts_paused_internally: true)

      expect(disposition_for(bank_account)).to eq(:payouts_paused)
    end

    it "flags a seller no longer paid over the Stripe bank rail" do
      user = create(:compliant_user)
      create(:user_compliance_info_uae, user:)
      _user, bank_account = seller_with_unlinked_row(user:)

      expect(disposition_for(bank_account)).to eq(:payout_method_changed)
    end

    it "does not look up a PayPal email while classifying a native bank row" do
      user, bank_account = seller_with_unlinked_row
      create(:merchant_account_paypal, user:)
      user.update_column(:payment_address, nil)
      expect_any_instance_of(User).not_to receive(:paypal_payout_email)

      expect(disposition_for(bank_account)).to eq(:provider_identity_unverified)
    end

    it "does not use the primary-only replica-lag watcher for a read-only scan" do
      _user, bank_account = seller_with_unlinked_row
      expect(ReplicaLagWatcher).not_to receive(:watch)

      expect(disposition_for(bank_account)).to eq(:provider_identity_unverified)
    end

    it "flags a connected Stripe account even if the payout processor still reads Stripe" do
      _user, bank_account = seller_with_unlinked_row
      allow_any_instance_of(User).to receive(:has_stripe_account_connected?).and_return(true)
      allow_any_instance_of(User).to receive(:current_payout_processor).and_return(PayoutProcessorType::STRIPE)

      expect(disposition_for(bank_account)).to eq(:payout_method_changed)
    end

    it "flags an Indian bank row" do
      _user, bank_account = seller_with_unlinked_row(bank_account_factory: :indian_bank_account)

      expect(disposition_for(bank_account)).to eq(:india_rail_restricted)
    end

    it "flags an Indian compliance country even if the bank row type is not Indian" do
      user, bank_account = seller_with_unlinked_row
      user.alive_user_compliance_info.update_column(:country, "India")

      expect(disposition_for(bank_account)).to eq(:india_rail_restricted)
    end

    it "leaves a debit-card row for manual review" do
      _user, bank_account = seller_with_unlinked_row
      bank_account.update_column(:type, "CardBankAccount")

      expect(disposition_for(bank_account)).to eq(:debit_card_row)
    end

    it "leaves an outstanding postal-code rejection to the same retry sweep" do
      user, bank_account = seller_with_unlinked_row(merchant_account: false)
      user.add_payout_note(content: "Stripe postal code rejected: invalid_postal_code — synthetic", seller_visible: false)

      expect(disposition_for(bank_account)).to eq(:bank_sync_retry_pending)
    end

    it "leaves a row with an outstanding bank-sync retry to the retry sweep" do
      user, bank_account = seller_with_unlinked_row
      user.add_payout_note(content: "Stripe bank sync failed: unknown — synthetic", seller_visible: false)

      expect(disposition_for(bank_account)).to eq(:bank_sync_retry_pending)
    end
  end
end
