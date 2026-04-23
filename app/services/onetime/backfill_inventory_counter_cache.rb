# frozen_string_literal: true

module Onetime
  class BackfillInventoryCounterCache
    BATCH_SIZE = 500

    def self.process(start_base_variant_id: 0, start_link_id: 0)
      new.process(start_base_variant_id:, start_link_id:)
    end

    def process(start_base_variant_id: 0, start_link_id: 0)
      backfill_base_variants(start_base_variant_id)
      backfill_links(start_link_id)
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

      def backfill_base_variants(start_id)
        BaseVariant.where("id >= ?", start_id).in_batches(of: BATCH_SIZE) do |batch|
          ReplicaLagWatcher.watch
          min_id, max_id = batch.minimum(:id), batch.maximum(:id)
          ActiveRecord::Base.connection.execute(<<~SQL.squish)
            UPDATE base_variants bv
            SET bv.sales_count_for_inventory_cache = COALESCE((
              SELECT SUM(p.quantity)
              FROM base_variants_purchases bvp
              INNER JOIN purchases p ON p.id = bvp.purchase_id
              LEFT JOIN subscriptions s ON s.id = p.subscription_id
              WHERE bvp.base_variant_id = bv.id
                AND #{qualifying_purchase_conditions}
            ), 0)
            WHERE bv.id BETWEEN #{min_id.to_i} AND #{max_id.to_i}
          SQL
          puts "BaseVariant backfill: reached id=#{max_id}"
        end
      end

      def backfill_links(start_id)
        Link.where("id >= ?", start_id).in_batches(of: BATCH_SIZE) do |batch|
          ReplicaLagWatcher.watch
          min_id, max_id = batch.minimum(:id), batch.maximum(:id)
          ActiveRecord::Base.connection.execute(<<~SQL.squish)
            UPDATE links l
            SET l.sales_count_for_inventory_cache = COALESCE((
              SELECT SUM(p.quantity)
              FROM purchases p
              LEFT JOIN subscriptions s ON s.id = p.subscription_id
              WHERE p.link_id = l.id
                AND #{qualifying_purchase_conditions}
            ), 0)
            WHERE l.id BETWEEN #{min_id.to_i} AND #{max_id.to_i}
          SQL
          puts "Link backfill: reached id=#{max_id}"
        end
      end
  end
end
