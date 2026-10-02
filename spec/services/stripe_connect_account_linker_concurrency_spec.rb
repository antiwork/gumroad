# frozen_string_literal: true

require "spec_helper"
require "timeout"

# Each writer runs on its own connection against real InnoDB locks, so these cannot share the fixture
# transaction; cleanup is explicit. Holds are SQL-level: the writer parks before a named statement
# while the linker runs on another connection.
describe StripeConnectAccountLinker, "racing payout writers" do
  self.use_transactional_tests = false

  let!(:seller) { create(:user) }
  let!(:crediting_user) { create(:user) }
  let!(:managed_account) do
    create(:merchant_account, user: seller, currency: Currency::USD, charge_processor_merchant_id: "acct_race_managed")
  end
  let(:auth_uid) { "acct_race_connect" }
  let(:stripe_account) { Stripe::Account.construct_from(id: auth_uid, default_currency: "usd", country: "US") }

  before do
    @held = Queue.new
    @proceed = Queue.new
    @hold_patterns = []
    example = self
    listener = Object.new
    listener.define_singleton_method(:start) { |_name, _id, payload| example.hold_if_pending(payload[:sql]) }
    listener.define_singleton_method(:finish) { |*| }
    @subscriber = ActiveSupport::Notifications.subscribe("sql.active_record", listener)
  end

  after do
    @proceed << true
    ActiveSupport::Notifications.unsubscribe(@subscriber)
    @threads&.each do |thread|
      next if thread.join(wait_seconds)

      thread.kill
      thread.join
    end
    Purchase.where(seller_id: seller.id).delete_all
    Link.where(user_id: seller.id).delete_all
    payment_ids = Payment.where(user_id: seller.id).ids
    ApplicationRecord.connection.execute("DELETE FROM payments_balances WHERE payment_id IN (#{payment_ids.presence&.join(',') || 'NULL'})")
    Payment.where(id: payment_ids).delete_all
    BalanceTransaction.where(user_id: seller.id).delete_all
    Credit.where(user_id: seller.id).delete_all
    Balance.where(user_id: seller.id).delete_all
    user_ids = [seller.id, crediting_user.id]
    Comment.where(commentable_type: "User", commentable_id: user_ids).delete_all
    MerchantAccount.where(user_id: user_ids).delete_all
    Affiliate.where(affiliate_user_id: user_ids).delete_all
    RefundPolicy.where(seller_id: user_ids).delete_all
    SellerProfile.where(seller_id: user_ids).delete_all
    PaperTrail::Version.where(item_type: "User", item_id: user_ids).delete_all
    User.where(id: user_ids).delete_all
  end

  def wait_seconds
    10
  end

  # InnoDB refreshes the innodb_trx snapshot behind sys.innodb_lock_waits only once it has gone
  # 0.1s unread, so a faster poll can keep returning the answer from before the wait began.
  def lock_wait_poll_seconds
    0.15
  end

  def hold_before(pattern)
    @hold_patterns << pattern
  end

  # Parks the racing thread before its nth statement against the balance tables (1-based).
  def hold_before_nth_ledger_query(count)
    @ledger_queries_before_hold = count - 1
  end

  def hold_if_pending(sql)
    if Thread.current[:racing_writer] && @ledger_queries_before_hold && sql.match?(/FROM `balances?(_transactions)?` /)
      if @ledger_queries_before_hold.zero?
        @ledger_queries_before_hold = nil
        @held << true
        @proceed.pop
      else
        @ledger_queries_before_hold -= 1
      end
    end
    return unless Thread.current[:racing_writer] && @hold_patterns.first&.match?(sql)

    @hold_patterns.shift
    @held << true
    @proceed.pop
  end

  def connection_id
    ActiveRecord::Base.connection.select_value("SELECT CONNECTION_ID()").to_i
  end

  # Runs the block on its own connection; returns the thread and that connection's id.
  def on_new_connection(racing_writer: false, &block)
    connection = Queue.new
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        connection << connection_id
        Thread.current[:racing_writer] = racing_writer
        block.call
      end
    end
    (@threads ||= []) << thread
    [thread, connection.pop(timeout: wait_seconds) || raise("no connection for the racing thread")]
  end

  def wait_for_hold
    @held.pop(timeout: wait_seconds) || raise("the writer never reached its hold")
  end

  def wait_until_blocked_on_user_row(waiting_pid, blocking_pid, table: "users")
    Timeout.timeout(wait_seconds) do
      loop do
        blocked = ActiveRecord::Base.connection.uncached do
          ActiveRecord::Base.connection.select_value(<<~SQL.squish).to_i.positive?
            SELECT COUNT(*) FROM sys.innodb_lock_waits
            WHERE waiting_pid = #{waiting_pid.to_i} AND blocking_pid = #{blocking_pid.to_i}
              AND locked_table = CONCAT('`', DATABASE(), '`.`#{table}`')
          SQL
        end
        break if blocked

        sleep lock_wait_poll_seconds
      end
    end
  end

  def link
    described_class.link(owner: User.find(seller.id), auth_uid:, stripe_account:)
  end

  def claim_payable_balances
    Payouts.send(:mark_balances_processing, Date.current, PayoutProcessorType::STRIPE, User.find(seller.id))
  end

  def connect_accounts
    MerchantAccount.where(charge_processor_merchant_id: auth_uid)
  end

  # What BalanceTransaction.create! leaves committed before update_balance! finds or creates a Balance.
  def create_unapplied_balance_transaction
    credit = create(:credit, user: seller, crediting_user:, merchant_account: managed_account, balance: nil, amount_cents: 5_00)
    amount = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: 5_00, net_cents: 5_00)
    BalanceTransaction.create!(user: seller, merchant_account: managed_account, credit:, issued_amount: amount, holding_amount: amount, update_user_balance: false)
  end

  def create_managed_balance(**attributes)
    create(:balance, user: seller, merchant_account: managed_account, date: 3.days.ago.to_date, **attributes)
  end

  context "when a payout claim and the replacement overlap" do
    it "refuses the replacement that waits behind a claim holding the seller lock" do
      balance = create_managed_balance
      claimed = nil
      claim, claim_pid = on_new_connection do
        ActiveRecord::Base.transaction do
          claimed = claim_payable_balances.first
          @held << true
          @proceed.pop
        end
      end
      wait_for_hold

      linking, linking_pid = on_new_connection { link }
      wait_until_blocked_on_user_row(linking_pid, claim_pid)
      expect(linking).to be_alive

      @proceed << true
      claim.value
      expect(Timeout.timeout(wait_seconds) { linking.value }).to eq(:unsettled_obligations)

      expect(claimed.map(&:id)).to eq([balance.id])
      expect(balance.reload).to be_processing
      expect(connect_accounts).to be_empty
      expect(managed_account.reload).to be_active
    end

    it "makes a claim wait behind the replacement and claim nothing from the retired account" do
      hold_before(/\AINSERT INTO `merchant_accounts`/)
      linking, linking_pid = on_new_connection(racing_writer: true) { link }
      wait_for_hold

      claim, claim_pid = on_new_connection { claim_payable_balances }
      wait_until_blocked_on_user_row(claim_pid, linking_pid)
      expect(claim).to be_alive

      @proceed << true
      expect(Timeout.timeout(wait_seconds) { linking.value }).to eq(:linked)
      expect(Timeout.timeout(wait_seconds) { claim.value }).to eq([[], false])

      expect(connect_accounts.sole).to be_active
      expect(managed_account.reload).not_to be_active
      expect(Balance.where(user_id: seller.id)).to be_empty
    end
  end

  context "when a balance transaction commits while the replacement waits for the seller lock" do
    it "reads the obligations only after acquiring the lock, so the late row counts" do
      holder, holder_pid = on_new_connection do
        User.find(seller.id).with_lock do
          @held << true
          @proceed.pop
        end
      end
      wait_for_hold

      linking, linking_pid = on_new_connection { link }
      wait_until_blocked_on_user_row(linking_pid, holder_pid)

      create_unapplied_balance_transaction

      @proceed << true
      holder.value
      expect(Timeout.timeout(wait_seconds) { linking.value }).to eq(:unsettled_obligations)
      expect(connect_accounts).to be_empty
      expect(managed_account.reload).to be_active
    end
  end

  context "when a balance transaction is applied between the two ledger reads under READ COMMITTED" do
    let!(:balance_transaction) { create_unapplied_balance_transaction }

    it "still counts the obligation, whichever statement runs second" do
      hold_before_nth_ledger_query(2)
      checking, = on_new_connection(racing_writer: true) do
        ActiveRecord::Base.transaction(isolation: :read_committed) { MerchantAccount.find(managed_account.id).unsettled_payout_obligations? }
      end
      held = @held.pop(timeout: 2)
      BalanceTransaction.find(balance_transaction.id).update_balance! if held
      @proceed << true

      expect(Timeout.timeout(wait_seconds) { checking.value }).to be(true)
      expect(Balance.where(user_id: seller.id, merchant_account_id: managed_account.id).count).to eq(held ? 1 : 0)
    end
  end

  context "when a failed payout returns its balances while the replacement runs" do
    let!(:balance) { create_managed_balance(state: "processing") }
    let!(:payment) do
      create(:payment, user: seller, processor: PayoutProcessorType::STRIPE, state: "processing", amount_cents: balance.amount_cents,
                       stripe_connect_account_id: managed_account.charge_processor_merchant_id, balances: [balance])
    end

    it "refuses while the return is uncommitted and the balances still read as processing" do
      hold_before(/\ACOMMIT/)
      returning, = on_new_connection(racing_writer: true) { StripePayoutProcessor.handle_stripe_event_payout_failed(Payment.find(payment.id)) }
      wait_for_hold

      expect(link).to eq(:unsettled_obligations)
      expect(balance.reload).to be_processing

      @proceed << true
      Timeout.timeout(wait_seconds) { returning.value }
      expect(balance.reload).to be_unpaid
      expect(payment.reload).to be_failed
      expect(connect_accounts).to be_empty
      expect(managed_account.reload).to be_active
    end

    it "refuses once the return has committed and the balances are unpaid again" do
      returning, = on_new_connection { StripePayoutProcessor.handle_stripe_event_payout_failed(Payment.find(payment.id)) }
      Timeout.timeout(wait_seconds) { returning.value }
      expect(balance.reload).to be_unpaid
      expect(payment.reload).to be_failed

      expect(link).to eq(:unsettled_obligations)

      expect(connect_accounts).to be_empty
      expect(managed_account.reload).to be_active
    end
  end

  context "when a credit creates the seller's first balance on the account" do
    let!(:balance_transaction) { create_unapplied_balance_transaction }

    it "refuses while the balance transaction is committed but the first balance row is not yet inserted" do
      hold_before(/\AINSERT INTO `balances`/)
      crediting, = on_new_connection(racing_writer: true) { BalanceTransaction.find(balance_transaction.id).update_balance! }
      wait_for_hold
      expect(Balance.where(user_id: seller.id)).to be_empty
      expect(BalanceTransaction.find(balance_transaction.id).balance_id).to be_nil

      expect(link).to eq(:unsettled_obligations)

      expect(connect_accounts).to be_empty
      expect(managed_account.reload).to be_active
      @proceed << true
      Timeout.timeout(wait_seconds) { crediting.value }
      landed = Balance.where(user_id: seller.id).sole
      expect(landed).to have_attributes(merchant_account_id: managed_account.id, state: "unpaid", amount_cents: 5_00)
      expect(managed_account.reload).to be_active
    end

    it "refuses once the credit has inserted the balance row, even before the amount is applied" do
      hold_before(/\AUPDATE `balances` SET `balances`.`amount_cents`/)
      crediting, = on_new_connection(racing_writer: true) { BalanceTransaction.find(balance_transaction.id).update_balance! }
      wait_for_hold
      expect(Balance.where(user_id: seller.id, merchant_account_id: managed_account.id).sole).to have_attributes(state: "unpaid", amount_cents: 0)

      expect(link).to eq(:unsettled_obligations)

      @proceed << true
      Timeout.timeout(wait_seconds) { crediting.value }
      expect(Balance.where(user_id: seller.id, merchant_account_id: managed_account.id).sole.amount_cents).to eq(5_00)
      expect(connect_accounts).to be_empty
      expect(managed_account.reload).to be_active
    end
  end

  def create_in_flight_sale(**attributes)
    create(:purchase, link: product, seller:, merchant_account: managed_account, purchase_state: "in_progress", **attributes)
  end

  # Returns the refusal instead of raising, so the thread's join in the cleanup does not re-raise it.
  def charge_on_managed_account
    ChargeProcessor.create_payment_intent_or_charge!(MerchantAccount.find(managed_account.id), instance_double(Chargeable, get_chargeable_for: :chargeable), 10_00, 1_00, "ref", "description")
  rescue ChargeProcessorErrorGeneric => e
    e
  end

  context "when a sale and the replacement overlap" do
    let!(:product) { create(:product, user: seller) }

    let(:processor) { instance_double(StripeChargeProcessor, create_payment_intent_or_charge!: nil) }

    before { allow(ChargeProcessor).to receive(:get_charge_processor).and_return(processor) }

    it "refuses the replacement that waits behind a charge holding the shared lock" do
      sale, sale_pid = on_new_connection do
        ActiveRecord::Base.transaction do
          MerchantAccount.find(managed_account.id).verify_live_for_charge!
          @in_flight_sale = create_in_flight_sale
          @held << true
          @proceed.pop
        end
      end
      wait_for_hold

      linking, linking_pid = on_new_connection { link }
      wait_until_blocked_on_user_row(linking_pid, sale_pid, table: "merchant_accounts")
      expect(linking).to be_alive

      @proceed << true
      sale.value
      expect(Timeout.timeout(wait_seconds) { linking.value }).to eq(:unsettled_obligations)

      expect(Purchase.find(@in_flight_sale.id)).to be_in_progress
      expect(connect_accounts).to be_empty
      expect(managed_account.reload).to be_active
    end

    it "refuses a charge that waits behind the replacement before any charge is created" do
      hold_before(/\AINSERT INTO `merchant_accounts`/)
      linking, linking_pid = on_new_connection(racing_writer: true) { link }
      wait_for_hold

      charging, charging_pid = on_new_connection { charge_on_managed_account }
      wait_until_blocked_on_user_row(charging_pid, linking_pid, table: "merchant_accounts")
      expect(charging).to be_alive

      @proceed << true
      expect(Timeout.timeout(wait_seconds) { linking.value }).to eq(:linked)
      refusal = Timeout.timeout(wait_seconds) { charging.value }
      expect(refusal).to be_a(ChargeProcessorErrorGeneric)
      expect(refusal.error_code).to eq(MerchantAccount::REPLACED_ACCOUNT_ERROR_CODE)

      expect(processor).not_to have_received(:create_payment_intent_or_charge!)
      expect(Balance.where(user_id: seller.id)).to be_empty
      expect(BalanceTransaction.where(user_id: seller.id)).to be_empty
      expect(connect_accounts.sole).to be_active
      expect(managed_account.reload).not_to be_active
    end

    it "lets charges on the account run side by side" do
      first, = on_new_connection do
        ActiveRecord::Base.transaction do
          MerchantAccount.find(managed_account.id).verify_live_for_charge!
          @held << true
          @proceed.pop
        end
      end
      wait_for_hold

      second, = on_new_connection { MerchantAccount.find(managed_account.id).verify_live_for_charge! }
      expect(Timeout.timeout(wait_seconds) { second.value }).to be_nil
      expect(first).to be_alive

      @proceed << true
      first.value
    end

    it "does not wait on a payout claim holding the seller lock" do
      claim, = on_new_connection do
        ActiveRecord::Base.transaction do
          claim_payable_balances
          @held << true
          @proceed.pop
        end
      end
      wait_for_hold

      charging, = on_new_connection { charge_on_managed_account }
      Timeout.timeout(wait_seconds) { charging.value }
      expect(processor).to have_received(:create_payment_intent_or_charge!)

      @proceed << true
      claim.value
    end
  end
end
