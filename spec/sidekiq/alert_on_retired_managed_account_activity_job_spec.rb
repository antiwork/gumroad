# frozen_string_literal: true

require "spec_helper"

describe AlertOnRetiredManagedAccountActivityJob do
  let(:seller) { create(:user) }
  let(:managed_account) do
    create(:merchant_account, user: seller, charge_processor_merchant_id: "acct_retired_activity")
  end
  let(:retired_at) { Time.zone.parse("2026-08-03T19:46:09Z") }

  before do
    managed_account.update!(deleted_at: retired_at)
    allow(InternalNotificationWorker).to receive(:perform_async)
  end

  def perform
    described_class.new.perform(managed_account.id, retired_at.utc.iso8601)
  end

  # The alert body, or nil when the job reported nothing.
  def reported_body
    captured = nil
    allow(InternalNotificationWorker).to receive(:perform_async) { |_room, _subject, body| captured = body }
    perform
    captured
  end

  def unapplied_balance_transaction(account: managed_account, user: seller)
    credit = create(:credit, user:, merchant_account: account, balance: nil, amount_cents: 5_00)
    amount = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: 5_00, net_cents: 5_00)
    # BalanceTransaction.create! takes a fixed keyword list and sets created_at itself, so the row is
    # backdated afterwards to place it after the retirement.
    BalanceTransaction.create!(user:, merchant_account: account, credit:, issued_amount: amount, holding_amount: amount,
                               update_user_balance: false).tap do |balance_transaction|
      balance_transaction.update_column(:created_at, retired_at + 1.hour)
    end
  end

  it "reports nothing while nothing landed on the retired account" do
    perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "reports a purchase that landed after the retirement" do
    purchase = create(:purchase, link: create(:product, user: seller), seller:, merchant_account: managed_account,
                                 purchase_state: "in_progress", created_at: retired_at + 1.hour)

    expect(reported_body).to include("1 row landed on")
    expect(reported_body).to include("purchase #{purchase.id}")
  end

  it "reports a charge that landed after the retirement" do
    charge = create(:charge, seller:, merchant_account: managed_account, created_at: retired_at + 1.hour)

    expect(reported_body).to include("charge #{charge.id}")
  end

  # The arrival production actually produced: a refund adds a balance transaction against a balance
  # that already exists, so nothing in `balances` moves and only this leg sees it.
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

  it "ignores rows that landed before the retirement" do
    create(:balance, user: seller, merchant_account: managed_account, state: "unpaid", amount_cents: 10_00,
                     created_at: retired_at - 1.hour)

    perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
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
end
