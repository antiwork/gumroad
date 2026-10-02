# frozen_string_literal: true

require "spec_helper"

describe AlertOnRetiredManagedAccountActivityJob do
  let(:seller) { create(:user) }
  let(:managed_account) do
    create(:merchant_account, user: seller, charge_processor_merchant_id: "acct_retired_activity")
  end
  let(:retired_at) { Time.zone.parse("2026-08-03T19:46:09Z") }

  before do
    # A check always runs from the marker the linker wrote on the retirement.
    managed_account.update!(deleted_at: retired_at, retired_activity_check_pending_at: retired_at.utc.iso8601)
    allow(InternalNotificationWorker).to receive(:perform_async)
  end

  def perform
    described_class.new.perform(managed_account.id, retired_at.utc.iso8601)
  end

  # The alert body, or nil when the job reported nothing. One run per example: the check is spent
  # when it reports, so a second copy of the job reports nothing.
  def reported_body
    return @reported_body if defined?(@reported_body)

    captured = nil
    allow(InternalNotificationWorker).to receive(:perform_async) { |_room, _subject, body| captured = body }
    perform
    @reported_body = captured
  end

  def unapplied_balance_transaction
    credit = create(:credit, user: seller, merchant_account: managed_account, balance: nil, amount_cents: 5_00)
    amount = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: 5_00, net_cents: 5_00)
    # BalanceTransaction.create! takes a fixed keyword list and sets created_at itself, so the row is
    # backdated afterwards to place it after the retirement.
    BalanceTransaction.create!(user: seller, merchant_account: managed_account, credit:, issued_amount: amount,
                               holding_amount: amount, update_user_balance: false).tap do |balance_transaction|
      balance_transaction.update_column(:created_at, retired_at + 1.hour)
    end
  end

  it "reports nothing while nothing landed on the retired account" do
    perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  # A sale that moved money left a charge and a balance transaction, both of which are read. The
  # purchase row is not read on its own: `merchant_account_id` is unindexed on purchases, so that leg
  # would walk the seller's whole history.
  it "does not report a purchase on its own" do
    create(:purchase, link: create(:product, user: seller), seller:, merchant_account: managed_account,
                      purchase_state: "in_progress", created_at: retired_at + 1.hour)

    perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "reports a charge that landed after the retirement" do
    charge = create(:charge, seller:, merchant_account: managed_account, created_at: retired_at + 1.hour)

    expect(reported_body).to include("charge #{charge.id}")
  end

  # A refund adds a balance transaction against a balance that already exists, so nothing in
  # `balances` moves and only this leg sees it.
  it "reports a balance transaction that landed after the retirement with no new balance row" do
    balance_transaction = unapplied_balance_transaction
    expect(Balance.where(merchant_account_id: managed_account.id)).to be_empty

    expect(reported_body).to include("balance_transaction #{balance_transaction.id}")
  end

  it "reports a balance that landed after the retirement" do
    balance = create(:balance, user: seller, merchant_account: managed_account, state: "unpaid", amount_cents: 62,
                               created_at: retired_at + 1.hour)

    expect(reported_body).to include("balance #{balance.id}")
    expect(reported_body).to include("unpaid, 62 usd cents")
  end

  # Balances has no index leading on merchant_account_id, so the balance leg has to carry the owner or
  # it reads the whole table on a job that exists to be cheap.
  it "reads balances through the owner as well as the account" do
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql] if payload[:sql].include?("FROM `balances`")
    end
    perform
    ActiveSupport::Notifications.unsubscribe(subscriber)

    expect(statements).not_to be_empty
    expect(statements).to all(match(/`balances`\.`user_id` = #{seller.id}\b/))
    expect(statements).to all(match(/`balances`\.`merchant_account_id` = #{managed_account.id}\b/))
  end

  it "ignores rows that landed before the retirement" do
    create(:balance, user: seller, merchant_account: managed_account, state: "unpaid", amount_cents: 10_00,
                     created_at: retired_at - 1.hour)

    perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  # deleted_at is stored to the second, so a row in the same second as the retirement is inside the
  # window the report covers.
  it "counts a row created in the same second as the retirement" do
    balance = create(:balance, user: seller, merchant_account: managed_account, state: "unpaid", amount_cents: 5_00,
                               created_at: retired_at)

    expect(reported_body).to include("balance #{balance.id}")
  end

  it "ignores activity on another merchant account" do
    other_account = create(:merchant_account, user: seller, charge_processor_merchant_id: "acct_other_retired")
    create(:balance, user: seller, merchant_account: other_account, state: "unpaid", amount_cents: 10_00,
                     created_at: retired_at + 1.hour)

    perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "writes one structured log line naming the account and what landed" do
    create(:balance, user: seller, merchant_account: managed_account, state: "unpaid", amount_cents: 10_00,
                     created_at: retired_at + 1.hour)

    expect(Rails.logger).to receive(:info).with(
      a_string_matching(/retired_managed_account_activity merchant_account_id=#{managed_account.id} /)
      .and(a_string_matching(/seller_id=#{seller.id} /))
      .and(a_string_matching(/landed_count=1 /))
    )

    perform
  end

  it "reports nothing for an account that is a live payout destination again" do
    managed_account.update!(deleted_at: nil, charge_processor_alive_at: Time.current)
    create(:balance, user: seller, merchant_account: managed_account, state: "unpaid", amount_cents: 10_00,
                     created_at: retired_at + 1.hour)

    perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "does nothing for a merchant account that no longer exists" do
    described_class.new.perform(managed_account.id + 10_000_000, retired_at.utc.iso8601)

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  # While the marker is set, DispatchPendingRetiredAccountChecksJob re-dispatches the check; clearing
  # it once this has run is what stops it being reported twice.
  it "clears the re-dispatch marker it ran from" do
    managed_account.update!(retired_activity_check_pending_at: retired_at.utc.iso8601)
    create(:balance, user: seller, merchant_account: managed_account, state: "unpaid", amount_cents: 10_00,
                     created_at: retired_at + 1.hour)

    perform

    expect(managed_account.reload.retired_activity_check_pending_at).to be_nil
  end

  it "clears the re-dispatch marker when nothing landed" do
    managed_account.update!(retired_activity_check_pending_at: retired_at.utc.iso8601)

    perform

    expect(managed_account.reload.retired_activity_check_pending_at).to be_nil
  end

  # The sweep re-dispatches a check whose scheduled copy is only delayed, so two copies of one check
  # can be queued; the marker is what lets the second one find it already reported.
  it "reports once when two copies of the check run" do
    create(:balance, user: seller, merchant_account: managed_account, state: "unpaid", amount_cents: 10_00,
                     created_at: retired_at + 1.hour)

    perform
    perform

    expect(InternalNotificationWorker).to have_received(:perform_async).once
  end

  it "reports nothing for a retirement the linker left no marker on" do
    managed_account.update!(retired_activity_check_pending_at: nil)
    create(:balance, user: seller, merchant_account: managed_account, state: "unpaid", amount_cents: 10_00,
                     created_at: retired_at + 1.hour)

    perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  # A seller who reconnects inside the tail leaves a marker for the later retirement. This check is
  # still owed its own report, but the later retirement's check is the one that reports from there —
  # spending its marker here would skip it.
  it "reports this retirement but leaves a later retirement's marker for its own check" do
    later_marker = (retired_at + 2.days).utc.iso8601
    create(:balance, user: seller, merchant_account: managed_account, state: "unpaid", amount_cents: 10_00,
                     created_at: retired_at + 1.hour)
    managed_account.update!(retired_activity_check_pending_at: later_marker)

    perform

    expect(InternalNotificationWorker).to have_received(:perform_async).once
    expect(managed_account.reload.retired_activity_check_pending_at).to eq(later_marker)
  end

  # The report exists to name the money event a late refund leaves behind. Balances fill the report
  # cap on their own, so a leg read only after them would be missing from the count as well as the
  # list.
  it "still reads the money-event legs when balances fill the report cap" do
    (described_class::MAX_REPORTED + 1).times do |index|
      create(:balance, user: seller, merchant_account: managed_account, state: "unpaid", amount_cents: 5_00,
                       created_at: retired_at + (index + 1).minutes)
    end
    balance_transaction = unapplied_balance_transaction

    body = reported_body
    expect(body).to include("At least")
    expect(body).to include("balance_transaction #{balance_transaction.id}")
  end
end
