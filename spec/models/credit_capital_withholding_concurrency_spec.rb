# frozen_string_literal: true

require "spec_helper"
require "timeout"

describe Credit, "concurrent Capital withholdings without a provable sale" do
  self.use_transactional_tests = false

  let(:financing_id) { "cptxn_concurrent_account_withholding" }

  before do
    @seller = create(:user)
    @merchant_account = create(:merchant_account, user: @seller, currency: Currency::USD)
  end

  after do
    BalanceTransaction.where(user: @seller).delete_all
    Credit.where(user: @seller).delete_all
    Balance.where(user: @seller).delete_all
    Comment.where(commentable: @seller).delete_all
    MerchantAccount.where(id: @merchant_account.id).delete_all
    User.where(id: @seller.id).delete_all
  end

  def capital_event
    { "type" => "capital.financing_transaction.created", "created" => 1.day.ago.to_i, "data" => { "object" => {
      "type" => "payment", "id" => financing_id, "account" => @merchant_account.charge_processor_merchant_id,
      "created_at" => 1.day.ago.to_i, "details" => { "currency" => "usd", "total_amount" => 780, "reason" => "automatic_withholding" }
    } } }
  end

  def blocked_on_row_lock?(process_id, table)
    ActiveRecord::Base.connection.uncached do
      ActiveRecord::Base.connection.select_value(<<~SQL.squish).to_i.positive?
        SELECT COUNT(*)
        FROM performance_schema.data_lock_waits AS lock_waits
        INNER JOIN performance_schema.data_locks AS requested_lock
          ON requested_lock.ENGINE_LOCK_ID = lock_waits.REQUESTING_ENGINE_LOCK_ID
        INNER JOIN performance_schema.threads AS requesting_thread
          ON requesting_thread.THREAD_ID = lock_waits.REQUESTING_THREAD_ID
        WHERE requesting_thread.PROCESSLIST_ID = #{process_id.to_i}
          AND requested_lock.OBJECT_SCHEMA = DATABASE()
          AND requested_lock.OBJECT_NAME = #{ActiveRecord::Base.connection.quote(table)}
      SQL
    end
  end

  # Holds the first delivery right after `pause_after_sql` runs inside its transaction, then starts the
  # second and releases the first once the second is blocked on `lock_table` (or has already finished,
  # which only happens when nothing serializes them).
  def deliver_concurrently(pause_after_sql:, lock_table:)
    first_paused = Queue.new
    release_first = Queue.new
    second_process_id = Queue.new
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next unless Thread.current[:capital_delivery] == :first && payload[:sql].start_with?(pause_after_sql)

      Thread.current[:capital_delivery] = nil
      first_paused << true
      release_first.pop
    end

    deliver = lambda do |role|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          second_process_id << connection.select_value("SELECT CONNECTION_ID()") if role == :second
          Thread.current[:capital_delivery] = role
          StripeChargeProcessor.handle_stripe_capital_loan_event(capital_event)
        end
      end
    end

    threads = []
    begin
      threads << deliver.call(:first)
      Timeout.timeout(10) { first_paused.pop }
      threads << deliver.call(:second)
      process_id = Timeout.timeout(10) { second_process_id.pop }
      Timeout.timeout(10) { sleep 0.01 until blocked_on_row_lock?(process_id, lock_table) || !threads.last.alive? }
      release_first << true
      Timeout.timeout(20) { threads.each(&:value) }
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
      release_first << true
      threads.each { _1.kill if _1.alive? }
      threads.each(&:join)
    end
  end

  def expect_one_applied_deduction
    credit = @seller.credits.where("json_data->'$.stripe_loan_paydown_id' = ?", financing_id).sole
    expect(BalanceTransaction.where(credit_id: credit.id).count).to eq(1)
    expect(credit.balance_id).to eq(credit.balance_transaction.balance_id)
    expect(Balance.where(user: @seller).sum(:amount_cents)).to eq(-780)
    expect(Balance.where(user: @seller).sum(:holding_amount_cents)).to eq(-780)
  end

  it "creates one credit when two first deliveries race" do
    deliver_concurrently(pause_after_sql: "INSERT INTO `credits`", lock_table: "merchant_accounts")

    expect_one_applied_deduction
  end

  it "creates one transaction when two retries of a saved credit race" do
    Credit.create!(user: @seller, merchant_account: @merchant_account, amount_cents: -780, stripe_loan_paydown_id: financing_id,
                   stripe_loan_paydown_reason: "automatic_withholding", stripe_loan_paydown_deducted_at: 1.day.ago.to_i,
                   stripe_loan_paydown_currency: Currency::USD, stripe_loan_paydown_usd_rate: "1.0", stripe_loan_paydown_usd_cents: -780)

    deliver_concurrently(pause_after_sql: "INSERT INTO `balance_transactions`", lock_table: "credits")

    expect_one_applied_deduction
  end
end
