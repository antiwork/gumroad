# frozen_string_literal: true

require "spec_helper"
require "timeout"

# Pins the blocker half of the lock-wait report (antiwork/gumroad-private#2583,
# direction 3). #7626 gave a `LockWaitTimeout` its own 409 and reported it once per
# product per window, but the payload still named nothing about the wait. These
# examples pin three things about the probe that now rides that one report: it runs
# only on the first occurrence in the window, it attaches what the server can see,
# and its own failure cannot turn the retryable 409 into a 500.
describe LinksController, type: :controller do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let(:save_params) { { id: product.unique_permalink, name: product.name } }

  before { sign_in seller }

  # The probe is three performance_schema reads; this counts executions of the one
  # that can only run once per probe, so "did the probe run?" is answered by the
  # real SQL rather than by a stub.
  def count_probe_runs
    runs = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      runs += 1 if payload[:sql].to_s.include?("performance_schema.events_statements_history")
    end
    yield
    runs
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  it "attaches the probe to the first report in the window only" do
    allow_any_instance_of(Link).to receive(:lock!).and_raise(ActiveRecord::LockWaitTimeout)

    reported = 0
    expect(ErrorNotifier).to receive(:notify).once do |_exception, **context|
      reported += 1
      expect(context[:lock_wait_probe]).to include(:waiting_statements, :link_row_lock_holders, :link_row_lock_waits)
    end

    runs = count_probe_runs do
      3.times { patch :update, params: save_params, as: :json }
    end

    expect(response).to have_http_status(:conflict)
    expect(reported).to eq(1)
    # Three requests, one probe. A rerun per request is the bug this pins.
    expect(runs).to eq(1)
  end

  it "answers the same retryable 409 when the probe itself fails" do
    allow_any_instance_of(Link).to receive(:lock!).and_raise(ActiveRecord::LockWaitTimeout)
    allow(controller).to receive(:editor_save_lock_probe_rows).and_raise(ActiveRecord::StatementInvalid)

    expect(ErrorNotifier).to receive(:notify).once do |_exception, **context|
      # The failure is recorded, not swallowed: the next occurrence has to show that
      # the probe ran and why it produced nothing.
      expect(context[:lock_wait_probe]).to eq(error: "ActiveRecord::StatementInvalid")
    end

    patch :update, params: save_params, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["error_code"]).to eq("product_save_busy")
    expect(response.headers["Retry-After"]).to eq("5")
  end

  it "records a failed read as an error marker instead of losing the whole payload" do
    allow(ActiveRecord::Base.connection).to receive(:select_all).and_raise(ActiveRecord::StatementInvalid, "SELECT command denied")

    # One unavailable table (no PROCESS privilege, instrumentation off) costs its own
    # row set: the other two reads still report.
    expect(controller.send(:editor_save_lock_probe_rows, "SELECT 1")).to eq(error: "ActiveRecord::StatementInvalid")
  end

  describe "against a real lock wait" do
    # The holder has to see a committed `links` row, so this group cannot run inside
    # the fixture transaction. Cleanup is explicit for the same reason.
    self.use_transactional_tests = false

    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }

    after do
      Price.where(link_id: product&.id).delete_all
      Link.where(id: product&.id).delete_all
      User.where(id: seller&.id).delete_all
    end

    it "keeps the statement that timed out and names the transaction holding the links row lock" do
      lock_taken = Queue.new
      release = Queue.new
      holder = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.transaction do
            Link.where(id: product.id).lock.pluck(:id)
            lock_taken << true
            release.pop
          end
        end
      end
      Timeout.timeout(15) { lock_taken.pop }

      connection = ActiveRecord::Base.connection
      previous = connection.select_value("SELECT @@innodb_lock_wait_timeout")
      begin
        connection.execute("SET SESSION innodb_lock_wait_timeout = 1")
        expect do
          connection.transaction do
            Link.where(id: product.id).lock.pluck(:id)
          end
        end.to raise_error(ActiveRecord::LockWaitTimeout)

        controller.instance_variable_set(:@product, product)
        probe = controller.send(:editor_save_lock_wait_probe)[:lock_wait_probe]

        # The wait is gone from data_lock_waits by now — that is the whole reason the
        # probe reads this connection's own statement history instead.
        waiting = probe[:waiting_statements]
        expect(waiting).to be_an(Array)
        expect(waiting.first["MYSQL_ERRNO"]).to eq(1205)
        expect(waiting.first["SQL_TEXT"]).to include("FOR UPDATE")

        # The blocker, on the identity that does not depend on it being mid-statement.
        holders = probe[:link_row_lock_holders]
        expect(holders).to be_an(Array)
        expect(holders.first["LOCK_DATA"]).to eq(product.id.to_s)
        expect(holders.first["holder_connection_id"]).to be_present
        expect(holders.first["trx_id"]).to be_present
        expect(probe[:save_transaction_open]).to be(false)
      ensure
        connection.execute("SET SESSION innodb_lock_wait_timeout = #{previous}")
      end
    ensure
      release << true if defined?(release) && release
      if holder && !holder.join(10)
        holder.kill
        holder.join
      end
    end
  end
end