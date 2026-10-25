# frozen_string_literal: true

require "spec_helper"

# Each racing writer runs on its own connection outside the test transaction, like separate web
# and Sidekiq processes. The first writer is held at a gate inside its transaction; the test only
# lets it go once MySQL reports the second one waiting on a lock, so the interleaving is fixed.
describe LowBalanceProbationRecovery, "concurrency", versioning: true do
  self.use_transactional_tests = false

  let(:lock_wait_timeout) { 10 }
  let(:join_timeout) { 30 }

  before do
    @results = {}
    @errors = {}
    @connection_ids = {}
    @held = Queue.new
    @release = Queue.new
    Sidekiq::Worker.clear_all
    @admin = create(:admin_user)
    @seller = create(:user)
  end

  after do
    @release.close
    user_ids = [@seller.id, @admin.id]
    comment_ids = Comment.where(commentable_type: "User", commentable_id: user_ids).pluck(:id)
    balance_ids = Balance.where(user_id: user_ids).pluck(:id)
    credit_ids = Credit.where(user_id: user_ids).pluck(:id)
    refund_policy_ids = RefundPolicy.where(seller_id: user_ids).pluck(:id)
    PaperTrail::Version.where(item_type: "User", item_id: user_ids).delete_all
    PaperTrail::Version.where(item_type: "Comment", item_id: comment_ids).delete_all
    PaperTrail::Version.where(item_type: "Balance", item_id: balance_ids).delete_all
    PaperTrail::Version.where(item_type: "Credit", item_id: credit_ids).delete_all
    PaperTrail::Version.where(item_type: "RefundPolicy", item_id: refund_policy_ids).delete_all
    Comment.where(id: comment_ids).delete_all
    BalanceTransaction.where(user_id: user_ids).delete_all
    Credit.where(id: credit_ids).delete_all
    Balance.where(id: balance_ids).delete_all
    Event.where(user_id: user_ids).delete_all
    RefundPolicy.where(id: refund_policy_ids).delete_all
    SellerProfile.where(seller_id: user_ids).delete_all
    GlobalAffiliate.where(affiliate_user_id: user_ids).delete_all
    User.where(id: user_ids).delete_all
    Sidekiq::Worker.clear_all
  end

  def probated_seller!(prior: :not_reviewed)
    @seller.mark_compliant!(author_name: "admin") if prior == :compliant
    @seller.send(:disable_refunds_and_put_on_probation!)
    create(:balance, user: @seller, amount_cents: 100_00)
    @seller.reload
  end

  def start_worker(name)
    Thread.new do
      Thread.current.report_on_exception = false
      Thread.current[:recovery_race_worker] = name
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        @connection_ids[name] = connection.select_value("SELECT CONNECTION_ID()")
        @results[name] = yield
      end
    rescue StandardError => e
      @errors[name] = e
    end
  end

  # Holds `worker` inside its transaction, right after `method` returns, until the test releases it.
  def hold_after(klass, method, worker)
    allow_any_instance_of(klass).to receive(method).and_wrap_original do |original, *args, **kwargs|
      result = original.call(*args, **kwargs)
      if Thread.current[:recovery_race_worker] == worker
        @held << worker
        @release.pop
      end
      result
    end
  end

  def wait_until_held(worker)
    Timeout.timeout(lock_wait_timeout) { expect(@held.pop).to eq(worker) }
  end

  # True once MySQL shows the worker's connection waiting for a lock; false if it never does.
  def waiting_for_lock?(worker)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + lock_wait_timeout
    loop do
      connection_id = @connection_ids[worker]
      if connection_id
        waits = ActiveRecord::Base.connection.select_value(<<~SQL.squish)
          SELECT COUNT(*) FROM performance_schema.data_lock_waits waits
          JOIN performance_schema.threads threads ON threads.THREAD_ID = waits.REQUESTING_THREAD_ID
          WHERE threads.PROCESSLIST_ID = #{Integer(connection_id)}
        SQL
        return true if waits.to_i.positive?
      end
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
  end

  def finish(*threads)
    @release << true while @release.num_waiting.positive?
    threads.each { |thread| expect(thread.join(join_timeout)).to be_present }
  end

  def decisions_after_probation
    probation = Comment.where(commentable: @seller, comment_type: Comment::COMMENT_TYPE_ON_PROBATION, author_name: "LowBalanceFraudCheck").order(:id).last
    Comment.where(commentable: @seller, comment_type: LowBalanceProbationRecovery::DECISION_COMMENT_TYPES).where("id > ?", probation.id).order(:id)
  end

  def recovery_comments
    Comment.where(commentable: @seller).where("idempotency_key LIKE 'low_balance_probation_recovery:%'")
  end

  def reviewed_facts = described_class.new(User.find(@seller.id)).evaluate.snapshot_facts

  it "makes a queued automatic recovery wait for an admin recovery, then stand down" do
    probated_seller!
    expected = reviewed_facts
    queued_copy = User.find(@seller.id)
    hold_after(described_class, :evaluate_rules, :admin)

    admin = start_worker(:admin) do
      described_class.new(User.find(@seller.id)).recover_for_admin!(actor: @admin, request_id: "req-race", expected:)
    end
    wait_until_held(:admin)
    job = start_worker(:job) { queued_copy.check_for_high_balance_and_remove_low_balance_probation! }

    job_waited = waiting_for_lock?(:job)
    @release << true
    finish(admin, job)

    expect(job_waited).to be(true), "the queued recovery did not wait for the admin recovery's lock"
    expect(@errors).to eq({})
    expect(decisions_after_probation.pluck(:author_id)).to eq([@admin.id])
    expect(@results[:admin].status).to eq(:recovered)
    expect(@results[:job].reason).to eq(:already_recovered)
  end

  it "keeps an admin decision that lands while a queued automatic recovery holds an older copy" do
    probated_seller!
    queued_copy = User.find(@seller.id)
    hold_after(User, :add_user_comment, :manual)

    manual = start_worker(:manual) { User.find(@seller.id).mark_compliant!(author_id: @admin.id) }
    wait_until_held(:manual)
    job = start_worker(:job) { queued_copy.check_for_high_balance_and_remove_low_balance_probation! }

    job_waited = waiting_for_lock?(:job)
    @release << true
    finish(manual, job)

    expect(User.find(@seller.id).user_risk_state).to eq("compliant")
    expect(@errors).to eq({})
    expect(job_waited).to be(true), "the queued recovery did not wait for the admin decision's lock"
    expect(recovery_comments.count).to eq(0)
  end

  it "does not recover past a risk comment written by a writer that never locks the account" do
    probated_seller!
    expected = reviewed_facts
    writer = start_worker(:comment_writer) do
      ActiveRecord::Base.transaction do
        Comment.create!(commentable: User.find(@seller.id), comment_type: Comment::COMMENT_TYPE_ON_PROBATION,
                        author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:recent_failed_purchases],
                        content: "High volume of failed purchases — flagged for review (payouts NOT paused).")
        @held << :comment_writer
        @release.pop
      end
    end
    wait_until_held(:comment_writer)
    recovery = start_worker(:admin) do
      described_class.new(User.find(@seller.id)).recover_for_admin!(actor: @admin, request_id: "req-race", expected:)
    end

    recovery_waited = waiting_for_lock?(:admin)
    @release << true
    finish(writer, recovery)

    expect(@errors).to eq({})
    expect(recovery_waited).to be(true), "the recovery did not wait for the uncommitted risk comment"
    expect(@results[:admin].status).to eq(:skipped)
    expect(@results[:admin].reason).to eq(:newer_risk_decision)
    expect(User.find(@seller.id).user_risk_state).to eq("on_probation")
  end

  it "does not recover on a balance a concurrent debit is lowering" do
    probated_seller!
    expected = reviewed_facts
    hold_after(Balance, :save!, :debit)

    debit = start_worker(:debit) { Credit.create_for_credit!(user: User.find(@seller.id), amount_cents: -60_00, crediting_user: @admin) }
    wait_until_held(:debit)
    recovery = start_worker(:admin) do
      described_class.new(User.find(@seller.id)).recover_for_admin!(actor: @admin, request_id: "req-race", expected:)
    end

    recovery_waited = waiting_for_lock?(:admin)
    @release << true
    finish(debit, recovery)

    expect(@errors).to eq({})
    expect(recovery_waited).to be(true), "the recovery did not wait for the uncommitted balance debit"
    expect(@results[:admin].status).to eq(:skipped)
    expect(@results[:admin].reason).to eq(:insufficient_balance)
    expect(Balance.where(user_id: @seller.id, state: "unpaid").sum(:amount_cents)).to eq(40_00)
    expect(User.find(@seller.id).user_risk_state).to eq("on_probation")
  end

  it "reports a recovery whose after-commit Stripe-lift enqueue failed as committed, not rolled back" do
    probated_seller!(prior: :compliant)
    expected = reviewed_facts
    allow(LiftPlatformStripePauseJob).to receive(:perform_async).and_raise(Redis::CannotConnectError)

    outcome = described_class.new(User.find(@seller.id)).recover_for_admin!(actor: @admin, request_id: "req-commit", expected:)

    expect(outcome.as_json).to include(outcome: "committed_unconfirmed", reason: "post_commit_step_failed", rolled_back: false)
    seen_elsewhere = start_worker(:reader) { User.where(id: @seller.id).pick(:user_risk_state) }
    finish(seen_elsewhere)
    expect(@results[:reader]).to eq("compliant")
    expect(recovery_comments.pluck(:author_id)).to eq([@admin.id])
  end
end
