# frozen_string_literal: true

class SalesRelatedProductsInfo < ApplicationRecord
  belongs_to :smaller_product, class_name: "Link"
  belongs_to :larger_product, class_name: "Link"

  validates_numericality_of :smaller_product_id, less_than: :larger_product_id

  scope :for_product_id, ->(product_id) { where("smaller_product_id = :product_id OR larger_product_id = :product_id", product_id:) }

  def self.find_or_create_info(product1_id, product2_id)
    if product1_id > product2_id
      find_or_create_by(smaller_product_id: product2_id, larger_product_id: product1_id)
    else
      find_or_create_by(smaller_product_id: product1_id, larger_product_id: product2_id)
    end
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  # How many product pairs to touch per SQL statement. Each pair contributes one short
  # VALUES tuple, so this bounds the size of every statement we send regardless of how
  # many products the buyer owns.
  SALES_COUNT_UPSERT_BATCH_SIZE = 100

  # Concurrent upserts deadlock against each other often enough to matter (a multi-item
  # cart fires one job per purchase, all landing here at once). Retrying is the remedy
  # rather than avoidance: under REPEATABLE READ the losing statement is InnoDB's chosen
  # victim, not a symptom of bad SQL. Keep the ceiling low — this sleeps a Sidekiq thread.
  UPSERT_CONTENTION_RETRIES = 3
  UPSERT_CONTENTION_BASE_BACKOFF = 0.05

  # Applies +1 (or -1) to the pairwise sales counter between `product_id` and each of
  # `related_product_ids`, creating the pair row if it does not exist yet.
  #
  # This runs once per successful purchase for every product the buyer already owns, so a
  # single sale can touch a lot of pairs. Two properties matter more than they look:
  #
  # 1. **Every statement is bounded.** An earlier version read the matching rows, then ran
  #    `where(id: [...]).in_batches(of: 1_000).update_all(...)`. `in_batches` only takes its
  #    cheap primary-key `BETWEEN` path on an *unscoped* relation — applied to a relation
  #    that already carries `where(id: [...])`, it re-ships the whole id list in every batch
  #    and merely adds a range predicate on top, so "batching" produced several copies of
  #    one huge statement instead of splitting it up. Slicing the ids ourselves is what
  #    actually bounds statement size.
  # 2. **One statement per slice, no read-then-write.** Reading which pairs exist and then
  #    updating them is racy: two concurrent purchases of the same pair can both see it
  #    missing and both try to insert, and whichever insert loses previously had its
  #    increment silently dropped by `INSERT IGNORE`. A single
  #    `INSERT ... ON DUPLICATE KEY UPDATE` against the unique index on
  #    (smaller_product_id, larger_product_id) lets MySQL resolve that per row, so a
  #    concurrent racer's increment is applied rather than discarded.
  #
  # Production MySQL runs `binlog_format = MIXED`, so a deterministic statement is binlogged
  # as a statement and every replica re-executes it on a single applier thread. That is why
  # statement size here shows up as replica lag (#1353) rather than just primary CPU.
  def self.update_sales_counts(product_id:, related_product_ids:, increment:)
    raise ArgumentError, "product_id must be an integer" unless product_id.is_a?(Integer)
    raise ArgumentError, "related_product_ids must be an array of integers" unless related_product_ids.all? { _1.is_a?(Integer) }

    # A product is never paired with itself (the model requires smaller < larger), and a
    # repeated id must not count twice — the caller derives these from purchase history,
    # which can legitimately list the same product more than once.
    pair_product_ids = related_product_ids.uniq - [product_id]
    return if pair_product_ids.empty?

    now_string = %("#{Time.current.to_fs(:db)}")
    sales_count_change = increment ? 1 : -1
    # A pair we are seeing for the first time starts at 1 for a sale. For a reversal
    # (refund, chargeback) there was no counted sale to take away, so it starts at 0 rather
    # than going negative.
    new_sales_count = increment ? 1 : 0

    # Sorted so that two overlapping statements — the norm for a multi-item cart, whose jobs
    # derive near-identical pair sets — take their row locks in the same order. This does not
    # address the insert-intention conflict at the tail of the clustered index, which is what
    # the retry below is for; it removes the separate lock-ordering deadlock on top of it.
    pairs = pair_product_ids.map { [product_id, _1].minmax }.sort

    pairs.each_slice(SALES_COUNT_UPSERT_BATCH_SIZE) do |slice|
      values_sql = slice.map do |smaller_id, larger_id|
        "(#{[smaller_id, larger_id, new_sales_count, now_string, now_string].join(', ')})"
      end.join(", ")

      # `sales_count` is incremented from its stored value rather than from VALUES(), because
      # the amount to add differs from the amount to insert: a reversal inserts 0 but must
      # subtract 1 from a pair that already exists.
      query = <<~SQL
        INSERT INTO #{table_name} (smaller_product_id, larger_product_id, sales_count, created_at, updated_at)
        VALUES #{values_sql}
        ON DUPLICATE KEY UPDATE sales_count = sales_count + (#{sales_count_change}), updated_at = #{now_string};
      SQL
      execute_upsert_with_contention_retry(query)
    end
  end

  # Retries are per statement, so slices that already committed are never replayed. Safe
  # because a deadlocked (or lock-wait-timed-out) statement rolls back whole and this runs
  # outside any wrapping transaction: nothing was counted, so nothing can double-count.
  def self.execute_upsert_with_contention_retry(query)
    attempts = 0
    begin
      ApplicationRecord.connection.execute(query)
    rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
      attempts += 1
      raise if attempts > UPSERT_CONTENTION_RETRIES

      # Jittered so two statements retrying against each other don't line up again.
      sleep(UPSERT_CONTENTION_BASE_BACKOFF * (2**(attempts - 1)) * (0.5 + Kernel.rand))
      retry
    end
  end

  # In: an array of product ids (typically: up to 50 latest cart and/or purchased products)
  # Out: An ordered ActiveRelation of products
  def self.related_products(product_ids, limit: 10)
    return Link.none if product_ids.blank?
    raise ArgumentError, "product_ids must be an array of integers" unless product_ids.all? { _1.is_a?(Integer) }
    raise ArgumentError, "limit must an integer" unless limit.is_a?(Integer)

    counts = Hash.new { 0 }
    product_ids.each_slice(100) do |product_ids_slice| # prevent huge sql queries
      products_counts = CachedSalesRelatedProductsInfo.where(product_id: product_ids_slice).map(&:normalized_counts)
      products_counts.flat_map(&:to_a).each do |product_id, sales_count|
        counts[product_id] += sales_count # sum sales counts for the same products across relationships
      end
    end

    related_products_ids = counts.
      except(*product_ids). # remove requested products
      sort { { 0 => (_2[0] <=> _1[0]), 1 => 1, -1 => -1 }[_2[1] <=> _1[1]] }. # sort by sales count (desc), then by product id (desc) in case of equality
      first(limit). # get the top results
      map(&:first) # return the product ids only

    Link.where(id: related_products_ids).in_order_of(:id, related_products_ids)
  end

  # Used when generating cached data for a product.
  # In: a single product id
  # Out: a hash of related products and the sales counts: { product_id => sales_count, ... }
  def self.related_product_ids_and_sales_counts(product_id, limit: 10)
    raise ArgumentError, "product_id must be an integer" unless product_id.is_a?(Integer)
    raise ArgumentError, "limit must be an integer" unless limit.is_a?(Integer)

    sql = <<~SQL.squish
      select product_id, sales_count
      from (#{two_sided_related_product_ids_and_sales_counts_sql(product_id:, limit:)}) t
      order by sales_count desc
      limit #{limit}
    SQL

    connection.exec_query(sql).rows.to_h
  end

  private
    def self.two_sided_related_product_ids_and_sales_counts_sql(product_id:, limit:)
      <<~SQL
        (#{one_sided_related_product_ids_and_sales_counts_sql(product_id:, limit:, column: :smaller_product_id, mirror_column: :larger_product_id)})
        union all
        (#{one_sided_related_product_ids_and_sales_counts_sql(product_id:, limit:, column: :larger_product_id, mirror_column: :smaller_product_id)})
      SQL
    end

    def self.one_sided_related_product_ids_and_sales_counts_sql(product_id:, limit:, column:, mirror_column:)
      <<~SQL
        select #{mirror_column} as product_id, sales_count
        from #{table_name}
        where #{column} = #{product_id}
        order by sales_count desc
        limit #{limit}
      SQL
    end
end
