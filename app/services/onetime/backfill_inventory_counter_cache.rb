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
      def backfill_base_variants(start_id)
        BaseVariant.where("id >= ?", start_id).in_batches(of: BATCH_SIZE) do |batch|
          ReplicaLagWatcher.watch
          batch.each do |variant|
            count = variant.purchases.counts_towards_inventory.sum(:quantity)
            BaseVariant.where(id: variant.id).update_all(sales_count_for_inventory_cache: count)
          end
          puts "BaseVariant backfill: reached id=#{batch.maximum(:id)}"
        end
      end

      def backfill_links(start_id)
        Link.where("id >= ?", start_id).in_batches(of: BATCH_SIZE) do |batch|
          ReplicaLagWatcher.watch
          batch.each do |link|
            count = link.sales.counts_towards_inventory.sum(:quantity)
            Link.where(id: link.id).update_all(sales_count_for_inventory_cache: count)
          end
          puts "Link backfill: reached id=#{batch.maximum(:id)}"
        end
      end
  end
end
