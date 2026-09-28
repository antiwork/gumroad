# frozen_string_literal: true

require "spec_helper"

describe SalesRelatedProductsInfo, "concurrent sales count upserts" do
  # Under transactional fixtures the upsert would run inside the fixture's transaction, without
  # READ COMMITTED or retries, and threads would share one connection.
  self.use_transactional_tests = false

  # Product ids far above anything factories create; no foreign keys, so no product rows needed.
  let(:base_id) { 9_000_000_000 + (SecureRandom.random_number(1_000_000) * 1_000) }

  after do
    described_class.where(smaller_product_id: base_id..(base_id + 999_999)).delete_all
  end

  def seed_pairs(pairs, sales_count: 0)
    values = pairs.map { |smaller, larger| "(#{smaller}, #{larger}, #{sales_count}, NOW(), NOW())" }.join(", ")
    described_class.connection.execute(<<~SQL)
      INSERT INTO sales_related_products_infos (smaller_product_id, larger_product_id, sales_count, created_at, updated_at)
      VALUES #{values}
    SQL
  end

  def sales_count(smaller, larger)
    described_class.find_by(smaller_product_id: smaller, larger_product_id: larger)&.sales_count
  end

  # Fails the first `times` upsert attempts, then lets them through. Tracks the attempt
  # count in @upsert_attempts.
  def fail_upserts(times:, with:)
    @upsert_attempts = 0
    allow(ApplicationRecord.connection).to receive(:execute).and_wrap_original do |original, sql, *args|
      if sql.include?("INSERT INTO #{described_class.table_name}")
        @upsert_attempts += 1
        raise with, "Deadlock found when trying to get lock" if @upsert_attempts <= times
      end
      original.call(sql, *args)
    end
  end

  it "counts every increment without deadlocking when unrelated buyers upsert existing and new pairs at once" do
    thread_count = 3
    rounds = 50
    next_id = base_id
    expected = Hash.new(0)
    fence_pairs = []
    errors = Queue.new
    isolation_statements = Queue.new
    deadlocks = Queue.new

    callback = lambda do |*, payload|
      isolation_statements << payload[:sql] if payload[:sql].include?("SET TRANSACTION ISOLATION LEVEL READ COMMITTED")
      deadlocks << true if payload[:exception_object].is_a?(ActiveRecord::Deadlocked)
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      rounds.times do
        # Each job is a different buyer: its own product, 15 pairs that already exist, 15 new ones.
        jobs = Array.new(thread_count) do
          # A fence row no job touches, so each job's pairs sit in their own unique-index gaps and
          # no job's duplicate-key gap lock can reach a neighbour's.
          fence = next_id += 1
          fence_pairs << [fence, next_id += 1]
          seed_pairs([fence_pairs.last])
          product_id = next_id += 1
          existing_partners = Array.new(15) { next_id += 1 }
          new_partners = Array.new(15) { next_id += 1 }
          seed_pairs(existing_partners.map { [product_id, _1] })
          [product_id, existing_partners + new_partners]
        end

        start = Queue.new
        threads = jobs.map do |product_id, partners|
          Thread.new do
            ApplicationRecord.connection_pool.with_connection(prevent_permanent_checkout: true) do
              start.pop
              described_class.update_sales_counts(product_id:, related_product_ids: partners, increment: true)
              partners.each { expected[[product_id, _1]] += 1 }
            rescue StandardError => error
              errors << error
            end
          end
        end
        thread_count.times { start << true }
        threads.each(&:join)
      end
    end

    expect(isolation_statements.size).to be >= rounds * thread_count
    # The fences keep jobs out of each other's unique-index gaps, so the only lock they can share
    # is the primary key's tail. A deadlock here means that tail lock is back.
    expect(deadlocks.size).to eq(0)
    raised = Array.new(errors.size) { errors.pop }.map { "#{_1.class}: #{_1.message}" }
    expect(raised).to be_empty, "#{raised.size} job(s) raised after retries: #{raised.tally}"
    actual = described_class.where(smaller_product_id: base_id..next_id).pluck(:smaller_product_id, :larger_product_id, :sales_count)
                            .to_h { |smaller, larger, count| [[smaller, larger], count] }
    expect(actual.except(*fence_pairs)).to eq(expected)
  end

  it "retries a deadlocked slice in a fresh READ COMMITTED transaction and counts it once" do
    product_id = base_id + 1
    partner_id = base_id + 2
    seed_pairs([[product_id, partner_id]])
    isolation_statements = 0
    callback = ->(*, payload) { isolation_statements += 1 if payload[:sql].include?("SET TRANSACTION ISOLATION LEVEL READ COMMITTED") }
    raised_once = false
    allow(ApplicationRecord.connection).to receive(:execute).and_wrap_original do |original, sql, *args|
      if !raised_once && sql.include?("INSERT INTO sales_related_products_infos")
        raised_once = true
        # A real deadlock arrives after the lazy transaction has begun, so begin it first.
        original.call("SELECT 1")
        raise ActiveRecord::Deadlocked, "Deadlock found when trying to get lock"
      end
      original.call(sql, *args)
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      described_class.update_sales_counts(product_id:, related_product_ids: [partner_id], increment: true)
    end

    expect(raised_once).to be(true)
    expect(isolation_statements).to eq(2)
    expect(described_class.find_by(smaller_product_id: product_id, larger_product_id: partner_id).sales_count).to eq(1)
  end

  context "when a standalone upsert hits contention" do
    before { allow(described_class).to receive(:sleep) }

    let(:product_id) { base_id + 1 }
    let(:partner_id) { base_id + 2 }

    it "retries a deadlocked statement and applies the increment" do
      fail_upserts(times: 1, with: ActiveRecord::Deadlocked)

      described_class.update_sales_counts(product_id:, related_product_ids: [partner_id], increment: true)

      expect(@upsert_attempts).to eq(2)
      expect(sales_count(product_id, partner_id)).to eq(1)
    end

    it "retries a lock wait timeout as well" do
      fail_upserts(times: 1, with: ActiveRecord::LockWaitTimeout)

      described_class.update_sales_counts(product_id:, related_product_ids: [partner_id], increment: true)

      expect(@upsert_attempts).to eq(2)
      expect(sales_count(product_id, partner_id)).to eq(1)
    end

    it "counts a retried pair exactly once" do
      seed_pairs([[product_id, partner_id]], sales_count: 4)
      fail_upserts(times: 2, with: ActiveRecord::Deadlocked)

      described_class.update_sales_counts(product_id:, related_product_ids: [partner_id], increment: true)

      expect(sales_count(product_id, partner_id)).to eq(5)
    end

    it "raises once the retry ceiling is exhausted so persistent contention still surfaces" do
      fail_upserts(times: described_class::UPSERT_CONTENTION_RETRIES + 1, with: ActiveRecord::Deadlocked)

      expect do
        described_class.update_sales_counts(product_id:, related_product_ids: [partner_id], increment: true)
      end.to raise_error(ActiveRecord::Deadlocked)

      expect(@upsert_attempts).to eq(described_class::UPSERT_CONTENTION_RETRIES + 1)
    end

    it "does not replay a slice that already committed" do
      partner_ids = Array.new(4) { base_id + 10 + _1 }
      stub_const("#{described_class}::SALES_COUNT_UPSERT_BATCH_SIZE", 1)
      # Fail only the third statement, after two slices have already committed.
      @upsert_attempts = 0
      allow(ApplicationRecord.connection).to receive(:execute).and_wrap_original do |original, sql, *args|
        if sql.include?("INSERT INTO #{described_class.table_name}")
          @upsert_attempts += 1
          raise ActiveRecord::Deadlocked, "Deadlock found when trying to get lock" if @upsert_attempts == 3
        end
        original.call(sql, *args)
      end

      described_class.update_sales_counts(product_id:, related_product_ids: partner_ids, increment: true)

      # 4 slices, one of them attempted twice.
      expect(@upsert_attempts).to eq(5)
      expect(partner_ids.map { sales_count(product_id, _1) }).to all(eq(1))
    end
  end

  context "when InnoDB picks the upsert as a deadlock victim" do
    let(:product_id) { base_id + 1 }
    let(:first_pair) { [product_id, base_id + 2] }
    let(:second_pair) { [product_id, base_id + 3] }
    let(:caller_pair) { [base_id + 4, base_id + 5] }

    before { seed_pairs([first_pair, second_pair], sales_count: 10) }

    def where_pair(pair)
      "smaller_product_id = #{pair[0]} AND larger_product_id = #{pair[1]}"
    end

    # Another session holds second_pair and, once the upsert has locked first_pair and is waiting
    # on second_pair, updates first_pair. Its 40 inserted rows make it the heavier transaction, so
    # InnoDB rolls back the upsert's. Returns what the block raised, if anything.
    def deadlock_upsert
      process_id = ApplicationRecord.connection.select_value("SELECT CONNECTION_ID()").to_i
      holding = Queue.new
      other = Thread.new do
        Thread.current.report_on_exception = false
        ApplicationRecord.connection_pool.with_connection do |connection|
          connection.transaction do
            seed_pairs(Array.new(40) { [base_id + 100 + _1, base_id + 200] })
            connection.execute("SELECT id FROM #{described_class.table_name} WHERE #{where_pair(second_pair)} FOR UPDATE")
            holding << true
            blocked = 200.times.any? do
              waiting = connection.uncached do
                connection.select_value(<<~SQL)
                  SELECT COUNT(*) FROM performance_schema.data_lock_waits AS lock_waits
                  INNER JOIN performance_schema.data_locks AS requested_lock
                    ON requested_lock.ENGINE_LOCK_ID = lock_waits.REQUESTING_ENGINE_LOCK_ID
                  INNER JOIN performance_schema.threads AS requesting_thread
                    ON requesting_thread.THREAD_ID = lock_waits.REQUESTING_THREAD_ID
                  WHERE requesting_thread.PROCESSLIST_ID = #{process_id}
                    AND requested_lock.OBJECT_SCHEMA = DATABASE()
                    AND requested_lock.OBJECT_NAME = #{connection.quote(described_class.table_name)}
                SQL
              end
              break true if waiting.to_i.positive?
              sleep(0.025)
              false
            end
            raise "the upsert never blocked on second_pair" unless blocked
            connection.execute("UPDATE #{described_class.table_name} SET sales_count = sales_count + 100 WHERE #{where_pair(first_pair)}")
          end
        end
      end
      expect(holding.pop(timeout: 10)).to be(true)
      deadlocks = 0
      callback = ->(*, payload) { deadlocks += 1 if payload[:exception_object].is_a?(ActiveRecord::Deadlocked) }
      error = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        yield
        nil
      rescue StandardError => e
        e
      end
      expect(other.join(30)).to be_truthy
      other.value
      expect(deadlocks).to eq(1)
      error
    ensure
      other&.kill&.join
    end

    def upsert_both_pairs
      described_class.update_sales_counts(product_id:, related_product_ids: [first_pair[1], second_pair[1]], increment: true)
    end

    it "retries a standalone upsert in a fresh transaction and counts it once" do
      error = deadlock_upsert { upsert_both_pairs }

      expect(error).to be_nil
      expect(sales_count(*first_pair)).to eq(10 + 100 + 1)
      expect(sales_count(*second_pair)).to eq(10 + 1)
    end

    [{}, { joinable: false }].each do |transaction_options|
      it "rolls back a caller's transaction(#{transaction_options}) whole instead of retrying the slice on its own" do
        error = deadlock_upsert do
          ApplicationRecord.transaction(**transaction_options) do
            seed_pairs([caller_pair])
            upsert_both_pairs
          end
        end

        aggregate_failures do
          expect(sales_count(*first_pair)).to eq(10 + 100)
          expect(sales_count(*second_pair)).to eq(10)
          expect(sales_count(*caller_pair)).to be_nil
          expect(error).to be_a(ActiveRecord::Deadlocked)
        end
      end
    end
  end
end
