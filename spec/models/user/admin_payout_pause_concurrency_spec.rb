# frozen_string_literal: true

require "spec_helper"

# Both risk writers rewrite the whole `flags` integer, which also carries payouts_paused_internally,
# and so does the admin pause endpoint, so neither may write from a copy loaded before the other
# committed. These run the admin pause on its own connection against the risk writer's row lock, so
# they cannot share the fixture transaction; cleanup is explicit.
describe User, "an admin payout pause racing a locked risk write" do
  self.use_transactional_tests = false

  let!(:admin) { create(:admin_user) }
  let!(:seller) { create(:user) }
  let!(:admin_token) { AdminApiToken.mint!(actor_user_id: admin.id) }

  before do
    @held = Queue.new
    @proceed = Queue.new
    @pending_sql_holds = []
    example = self
    listener = Object.new
    listener.define_singleton_method(:start) { |_name, _id, payload| example.hold_if_pending_sql(payload[:sql]) }
    listener.define_singleton_method(:finish) { |*| }
    @subscriber = ActiveSupport::Notifications.subscribe("sql.active_record", listener)
  end

  after do
    ActiveSupport::Notifications.unsubscribe(@subscriber)
    user_ids = [admin.id, seller.id]
    AdminApiAuditLog.where(actor_user_id: user_ids).delete_all
    AdminApiToken.where(actor_user_id: user_ids).delete_all
    Event.where(user_id: user_ids).delete_all
    Comment.where(commentable_type: "User", commentable_id: user_ids).delete_all
    Affiliate.where(affiliate_user_id: user_ids).delete_all
    RefundPolicy.where(seller_id: user_ids).delete_all
    SellerProfile.where(seller_id: user_ids).delete_all
    PaperTrail::Version.where(item_type: "User", item_id: user_ids).delete_all
    User.where(id: user_ids).delete_all
  end

  def connection_id
    ActiveRecord::Base.connection.select_value("SELECT CONNECTION_ID()").to_i
  end

  # InnoDB refreshes the innodb_trx snapshot behind sys.innodb_lock_waits only once it has gone
  # 0.1s unread, so polling any faster can keep returning the answer from before the wait began.
  def lock_wait_poll_seconds
    0.15
  end

  # performance_schema can attribute a waiting lock to the thread that holds it, so go by each
  # transaction's own connection as innodb_trx reports it.
  def waiting_on_users_row_lock?(waiting_process_id, blocking_process_id)
    ActiveRecord::Base.connection.uncached do
      ActiveRecord::Base.connection.select_value(<<~SQL.squish).to_i.positive?
        SELECT COUNT(*) FROM sys.innodb_lock_waits
        WHERE waiting_pid = #{waiting_process_id.to_i}
          AND blocking_pid = #{blocking_process_id.to_i}
          AND locked_table = CONCAT('`', DATABASE(), '`.`users`')
      SQL
    end
  end

  # The real endpoint, so the request loads the user and writes the pause the way production does.
  def pause_payouts_through_admin_api
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host!(VALID_API_REQUEST_HOSTS.first)
    session.post(Rails.application.routes.url_helpers.pause_api_internal_admin_payouts_path,
                 params: { user_id: seller.external_id, reason: "Manual review" },
                 headers: { "Authorization" => "Bearer #{admin_token}" })
    session.response.status
  end

  # Parks the risk write (and only it) until the admin pause has had its chance to run.
  def hold_risk_write
    return unless Thread.current[:locked_risk_write]

    @held << true
    @proceed.pop
  end

  def hold_risk_write_before(*sql_patterns)
    @pending_sql_holds.concat(sql_patterns)
  end

  def hold_if_pending_sql(sql)
    return unless Thread.current[:locked_risk_write] && @pending_sql_holds.first&.match?(sql)

    @pending_sql_holds.shift
    hold_risk_write
  end

  # Runs the block on its own connection. The admin pause starts on a third connection at the risk
  # write's first hold. At each hold we record whether the admin pause is waiting on the risk
  # write's row lock; when nothing holds that lock it finishes instead.
  def pause_as_admin_during(holds:, &risk_write)
    risk_connection = Queue.new
    risk_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        risk_connection << connection_id
        Thread.current[:locked_risk_write] = true
        risk_write.call
      end
    end
    risk_process_id = risk_connection.pop(timeout: 10) || raise("the risk write never got a connection")
    admin_connection = Queue.new
    admin_thread = nil
    admin_process_id = nil
    admin_waiting = Array.new(holds) do |hold|
      unless @held.pop(timeout: 10)
        risk_thread.value unless risk_thread.alive?
        raise "the risk write never reached hold #{hold + 1} of #{holds}"
      end
      admin_thread ||= Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          admin_connection << connection_id
          pause_payouts_through_admin_api
        end
      end
      admin_process_id ||= admin_connection.pop(timeout: 10) || raise("the admin pause never got a connection")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      waiting = loop do
        break true if waiting_on_users_row_lock?(admin_process_id, risk_process_id)
        break false unless admin_thread.alive?
        raise "the admin pause neither waited on the row lock nor finished" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep lock_wait_poll_seconds
      end
      @proceed << true
      waiting
    end
    [risk_thread, admin_thread].each { expect(_1.join(20)).to eq(_1) }

    { admin_waiting:, admin_status: admin_thread.value, connections: [connection_id, risk_process_id, admin_process_id] }
  ensure
    holds.times { @proceed << true }
    [risk_thread, admin_thread].compact.each { stop(_1) }
  end

  def stop(thread)
    return if thread.join(10)

    thread.kill
    thread.join
  rescue StandardError
    # Its error already surfaced through the join above, or through the failure that brought us here.
  end

  it "holds the admin pause until the compliant transition has saved its flags, then keeps it" do
    seller.update!(user_risk_state: "on_probation", refunds_disabled: true)
    # The first write after the transition's locked reads, then the final flag save (enable_refunds!).
    hold_risk_write_before(/\AUPDATE `users` SET .*`user_risk_state`/, /\AUPDATE `users` SET .*`flags`/)

    contention = pause_as_admin_during(holds: 2) { User.find(seller.id).mark_compliant!(author_id: admin.id) }

    expect(contention[:connections].uniq.size).to eq(3)
    expect(contention[:admin_waiting]).to eq([true, true])
    expect(contention[:admin_status]).to eq(200)
    seller.reload
    expect(seller).to be_compliant
    expect(seller.refunds_disabled?).to be(false)
    expect(seller.payouts_paused_internally?).to be(true)
    expect(seller.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_ADMIN)
  end

  it "holds the admin pause until the chargeback-rate pause and its comment commit, then keeps the admin source" do
    risk_copy = User.find(seller.id)
    allow(risk_copy).to receive(:lost_chargebacks_for_payout_gate).and_return({ volume: "4.2%", count: "15.0%" })
    # Hold before the pause write starts rather than at its UPDATE: saving payouts_paused_by locks
    # the row on its own (JsonData's merge), which would hide a missing outer lock.
    allow(risk_copy).to receive(:update!).and_wrap_original do |original, *args, **kwargs|
      hold_risk_write
      original.call(*args, **kwargs)
    end
    hold_risk_write_before(/\AINSERT INTO `comments`/)

    contention = pause_as_admin_during(holds: 2) { Purchase.new(seller: risk_copy).pause_payouts_for_seller_based_on_chargeback_rate! }

    expect(contention[:connections].uniq.size).to eq(3)
    expect(contention[:admin_waiting]).to eq([true, true])
    expect(contention[:admin_status]).to eq(200)
    seller.reload
    expect(seller.payouts_paused_internally?).to be(true)
    expect(seller.payouts_paused_by).to eq(admin.id)
    expect(seller.comments.where(author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:high_chargeback_rate]).count).to eq(1)
  end
end
