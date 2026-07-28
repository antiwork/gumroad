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

  # How many (smaller_product_id, larger_product_id) pairs a single statement may touch.
  # Keeping statements small matters beyond the primary: production replicates with
  # binlog_format = MIXED, so a deterministic multi-row statement is re-executed verbatim
  # on every replica by a single applier thread. One oversized statement once stalled
  # replication for hours (see gumroad-private#1353), which is why this path was disabled.
  UPDATE_SALES_COUNTS_SLICE_SIZE = 100

  def self.update_sales_counts(product_id:, related_product_ids:, increment:)
    return if related_product_ids.empty?
    raise ArgumentError, "product_id must be an integer" unless product_id.is_a?(Integer)
    raise ArgumentError, "related_product_ids must be an array of integers" unless related_product_ids.all? { _1.is_a?(Integer) }

    now_string = connection.quote(Time.current.to_fs(:db))
    # A pair we've never seen starts at 1 for an increment. For a decrement (e.g. a refund)
    # it starts at 0, not -1: a refund for a pair we never counted means the pair simply has
    # no sales. This mirrors what the previous read-then-update-then-insert code did.
    new_row_sales_count = increment ? 1 : 0
    sales_count_change = increment ? 1 : -1

    # Deduplicate before upserting: a duplicate id in the input must not double-count.
    # The old implementation got this for free (a second INSERT IGNORE for the same pair
    # was a no-op), so we preserve that behavior explicitly here.
    ids = related_product_ids.uniq - [product_id]

    # A single upsert per slice replaces the old SELECT ids -> UPDATE ... WHERE id IN (...)
    # -> INSERT IGNORE sequence. The upsert is keyed off the unique index on
    # (smaller_product_id, larger_product_id), which closes the read-then-write race and,
    # more importantly, removes the unbounded `id IN (...)` UPDATE whose replication cost
    # is what got this collection path disabled (gumroad-private#1353 / #1406).
    ids.each_slice(UPDATE_SALES_COUNTS_SLICE_SIZE) do |ids_slice|
      values_sql = ids_slice.map do |related_product_id|
        smaller_id, larger_id = [product_id, related_product_id].minmax
        "(#{smaller_id}, #{larger_id}, #{new_row_sales_count}, #{now_string}, #{now_string})"
      end.join(", ")

      connection.execute(<<~SQL.squish)
        INSERT INTO #{table_name} (smaller_product_id, larger_product_id, sales_count, created_at, updated_at)
        VALUES #{values_sql}
        ON DUPLICATE KEY UPDATE
          sales_count = sales_count + #{sales_count_change},
          updated_at = VALUES(updated_at)
      SQL
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
