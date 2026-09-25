# frozen_string_literal: true

require "spec_helper"

describe SalesRelatedProductsInfo, "concurrent sales count upserts" do
  # Transactional fixtures would swallow the isolation level (Rails turns it into a savepoint)
  # and share one connection across threads, so this needs real, separate transactions.
  self.use_transactional_tests = false

  # Product ids far above anything factories create; no foreign keys, so no product rows needed.
  let(:base_id) { 9_000_000_000 + (SecureRandom.random_number(1_000_000) * 1_000) }

  after do
    described_class.where(smaller_product_id: base_id..(base_id + 999_999)).delete_all
  end

  def seed_pairs(pairs)
    values = pairs.map { |smaller, larger| "(#{smaller}, #{larger}, 0, NOW(), NOW())" }.join(", ")
    described_class.connection.execute(<<~SQL)
      INSERT INTO sales_related_products_infos (smaller_product_id, larger_product_id, sales_count, created_at, updated_at)
      VALUES #{values}
    SQL
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
end
