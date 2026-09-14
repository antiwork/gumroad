# frozen_string_literal: true

require "spec_helper"
require "timeout"

# Pins the fail-fast half of the editor save's row lock (antiwork/gumroad-private#2583).
# A save that arrives while another save of the same product holds the `links` row must
# answer the retryable 409 within the bound — not park its Puma thread and DB connection
# on `@product.lock!` for MySQL's 50s default and then answer the same 409 anyway.
describe LinksController, type: :controller do
  let(:save_params) { { id: product.unique_permalink, name: product.name } }

  describe "with a concurrent save holding the product's row lock" do
    # The holder has to see a committed `links` row, so this group cannot run inside
    # the fixture transaction. Cleanup is explicit for the same reason.
    self.use_transactional_tests = false

    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }

    before { sign_in seller }

    after do
      Price.where(link_id: product&.id).delete_all
      Link.where(id: product&.id).delete_all
      User.where(id: seller&.id).delete_all
    end

    it "answers the retryable 409 inside the bound instead of waiting out the server's lock timeout" do
      # Materialized here, on this example's connection: a record first touched inside the
      # holder thread is created on that thread's connection instead.
      product

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

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      patch :update, params: save_params, as: :json
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["error_code"]).to eq("product_save_busy")
      # The bound is the thing under test: MySQL's default is 50s, and a save that waits
      # it out is the shape this exists to prevent. Generous, so a slow CI box is not the
      # failure — an unbounded wait still blows past it by an order of magnitude.
      expect(elapsed).to be < 15
    ensure
      release << true if defined?(release) && release
      if holder && !holder.join(10)
        holder.kill
        holder.join
      end
    end

    it "restores the session's lock wait timeout, so the pooled connection hands it to no one else" do
      previous = ActiveRecord::Base.connection.select_value("SELECT @@SESSION.innodb_lock_wait_timeout")

      patch :update, params: save_params, as: :json

      expect(response).to have_http_status(:success)
      expect(ActiveRecord::Base.connection.select_value("SELECT @@SESSION.innodb_lock_wait_timeout")).to eq(previous)
    end
  end

  describe "the bound's blast radius" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }

    before { sign_in seller }

    # The save's own lock wait is the only one inside the bound, and the products that are
    # not the one being saved must still queue on their own timeout rather than fail here.
    it "bounds the save's lock wait and leaves the rest of the request at the server's default" do
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
        sql = payload[:sql].to_s
        statements << sql if sql.match?(/innodb_lock_wait_timeout|FOR UPDATE/i)
      end

      begin
        patch :update, params: save_params, as: :json
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      expect(response).to have_http_status(:success)
      bounded = statements.index { |sql| sql.match?(/SET SESSION innodb_lock_wait_timeout = #{LinksController::EDITOR_SAVE_LOCK_WAIT_TIMEOUT_SECONDS}\z/) }
      lock_taken = statements.index { |sql| sql.match?(/FOR UPDATE/i) }
      restored = statements.index { |sql| sql.match?(/SET SESSION innodb_lock_wait_timeout = \d+\z/) && !sql.end_with?("= #{LinksController::EDITOR_SAVE_LOCK_WAIT_TIMEOUT_SECONDS}") }

      expect(bounded).to be_present
      expect(lock_taken).to be_present
      expect(restored).to be_present
      # Before the lock is taken, so the wait it starts is the bounded one; and after it,
      # so no later statement in the request waits on the bound.
      expect(bounded).to be < lock_taken
      expect(restored).to be > lock_taken
    end
  end
end