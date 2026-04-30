# frozen_string_literal: true

module Onetime
  class BackfillInventoryCounterCache
    BATCH_SIZE = 1_000

    def self.process(
      start_base_variant_id: 0,
      end_base_variant_id: nil,
      start_link_id: 0,
      end_link_id: nil,
      batch_size: BATCH_SIZE
    )
      new.process(
        start_base_variant_id:,
        end_base_variant_id:,
        start_link_id:,
        end_link_id:,
        batch_size:,
      )
    end

    def process(
      start_base_variant_id: 0,
      end_base_variant_id: nil,
      start_link_id: 0,
      end_link_id: nil,
      batch_size: BATCH_SIZE
    )
      backfill_base_variants(start_base_variant_id, end_base_variant_id, batch_size)
      backfill_links(start_link_id, end_link_id, batch_size)
    end

    private
      def qualifying_purchase_conditions
        flag = Purchase.flag_mapping["flags"]
        states_sql = Purchase::COUNTS_TOWARDS_INVENTORY_STATES.map { |s| ActiveRecord::Base.connection.quote(s) }.join(",")
        <<~SQL.squish
          p.purchase_state IN (#{states_sql})
          AND (p.flags IS NULL OR p.flags & #{flag[:is_additional_contribution]} = 0)
          AND (p.flags & #{flag[:is_archived_original_subscription_purchase]} = 0)
          AND (
            p.subscription_id IS NULL
            OR p.flags & #{flag[:is_original_subscription_purchase]} != 0
            OR p.flags & #{flag[:is_gift_receiver_purchase]} != 0
          )
          AND (p.subscription_id IS NULL OR s.deactivated_at IS NULL)
        SQL
      end

      def bounded_scope(model, start_id, end_id)
        scope = model.where("id >= ?", start_id)
        scope = scope.where("id <= ?", end_id) if end_id
        scope
      end

      def backfill_base_variants(start_id, end_id, batch_size)
        bounded_scope(BaseVariant, start_id, end_id).in_batches(of: batch_size) do |batch|
          ReplicaLagWatcher.watch
          min_id, max_id = batch.minimum(:id), batch.maximum(:id)
          ActiveRecord::Base.connection.execute(<<~SQL.squish)
            UPDATE base_variants bv
            LEFT JOIN (
              SELECT bvp.base_variant_id AS bv_id, SUM(p.quantity) AS total
              FROM base_variants_purchases bvp
              INNER JOIN purchases p ON p.id = bvp.purchase_id
              LEFT JOIN subscriptions s ON s.id = p.subscription_id
              WHERE bvp.base_variant_id BETWEEN #{min_id.to_i} AND #{max_id.to_i}
                AND #{qualifying_purchase_conditions}
              GROUP BY bvp.base_variant_id
            ) agg ON agg.bv_id = bv.id
            SET bv.sales_count_for_inventory_cache = COALESCE(agg.total, 0)
            WHERE bv.id BETWEEN #{min_id.to_i} AND #{max_id.to_i}
          SQL
          puts "BaseVariant backfill: reached id=#{max_id}"
        end
      end

      def backfill_links(start_id, end_id, batch_size)
        bounded_scope(Link, start_id, end_id).in_batches(of: batch_size) do |batch|
          ReplicaLagWatcher.watch
          min_id, max_id = batch.minimum(:id), batch.maximum(:id)
          ActiveRecord::Base.connection.execute(<<~SQL.squish)
            UPDATE links l
            LEFT JOIN (
              SELECT p.link_id AS l_id, SUM(p.quantity) AS total
              FROM purchases p
              LEFT JOIN subscriptions s ON s.id = p.subscription_id
              WHERE p.link_id BETWEEN #{min_id.to_i} AND #{max_id.to_i}
                AND #{qualifying_purchase_conditions}
              GROUP BY p.link_id
            ) agg ON agg.l_id = l.id
            SET l.sales_count_for_inventory_cache = COALESCE(agg.total, 0)
            WHERE l.id BETWEEN #{min_id.to_i} AND #{max_id.to_i}
          SQL
          puts "Link backfill: reached id=#{max_id}"
        end
      end
  end
end
