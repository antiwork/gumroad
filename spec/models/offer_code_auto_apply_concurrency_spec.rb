# frozen_string_literal: true

require "spec_helper"
require "timeout"

describe OfferCode, "auto apply concurrency" do
  self.use_transactional_tests = false

  def wait_for_row_lock(process_id:, table:)
    Timeout.timeout(10) do
      loop do
        lock_wait_count = ActiveRecord::Base.connection.select_value(<<~SQL.squish)
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
        break if lock_wait_count.to_i.positive?

        sleep 0.01
      end
    end
  end

  before do
    @seller = create(:user, username: "oca#{SecureRandom.hex(8)}")
    @existing_code = @seller.offer_codes.create!(code: "tab#{SecureRandom.hex(3)}", amount_percentage: 20, universal: true, products: [])
  end

  after do
    OfferCode.where(user_id: @seller&.id).delete_all
    Affiliate.where(affiliate_user_id: @seller&.id).delete_all
    RefundPolicy.where(seller_id: @seller&.id).delete_all
    UserComplianceInfo.where(user_id: @seller&.id).delete_all
    User.where(id: @seller&.id).delete_all
  end

  it "lets only one of two concurrent saves turn auto apply on" do
    first_lock = Queue.new
    release_first = Queue.new
    second_connection_id = Queue.new
    results = Queue.new
    errors = Queue.new
    first_writer = nil
    second_writer = nil

    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      next unless Thread.current[:auto_apply_first_writer]
      next unless payload[:sql].include?("FROM `users`") && payload[:sql].include?("FOR UPDATE")

      Thread.current[:auto_apply_first_writer] = false
      first_lock << true
      release_first.pop
    end

    first_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Thread.current[:auto_apply_first_writer] = true
        code = User.find(@seller.id).offer_codes.build(code: "new#{SecureRandom.hex(3)}", amount_percentage: 30, universal: true, products: [], auto_apply: true)
        results << [:first, code.save, code.errors.full_messages]
      rescue StandardError => error
        errors << error
      ensure
        Thread.current[:auto_apply_first_writer] = false
      end
    end
    Timeout.timeout(10) { first_lock.pop }

    second_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        second_connection_id << ActiveRecord::Base.connection.select_value("SELECT CONNECTION_ID()")
        code = OfferCode.find(@existing_code.id)
        # Like Checkout::DiscountsController#update: the association writes read before validation.
        results << [:second, code.update(auto_apply: true, products: [], excluded_products: []), code.errors.full_messages]
      rescue StandardError => error
        errors << error
      end
    end
    process_id = Timeout.timeout(10) { second_connection_id.pop }
    wait_for_row_lock(process_id:, table: "users")

    expect(second_writer).to be_alive
    expect(results).to be_empty

    release_first << true
    [first_writer, second_writer].each { expect(_1.join(10)).to be_present }

    expect(errors).to be_empty
    outcomes = 2.times.map { results.pop }.to_h { |writer, saved, messages| [writer, [saved, messages]] }
    expect(outcomes[:first]).to eq([true, []])
    expect(outcomes[:second].first).to be(false)
    expect(outcomes[:second].last.join).to include("is already applied automatically")
    expect(OfferCode.alive.where(user_id: @seller.id, auto_apply: true).count).to eq(1)
    expect(@existing_code.reload.auto_apply).to be(false)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    release_first << true if defined?(release_first) && release_first
    [first_writer, second_writer].compact.each do |thread|
      next if thread.join(1)

      thread.kill
      thread.join
    end
  end
end
