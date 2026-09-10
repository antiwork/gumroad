# frozen_string_literal: true

module Onetime
  class RemoveCrossProductFileEmbeds
    BATCH_SIZE = 100

    def self.process(dry_run: true, batch_size: BATCH_SIZE)
      new.process(dry_run:, batch_size:)
    end

    def process(dry_run: true, batch_size: BATCH_SIZE)
      cleaned = 0

      RichContent.alive.in_batches(of: batch_size) do |batch|
        ReplicaLagWatcher.watch
        batch.each do |rich_content|
          foreign_ids = rich_content.cross_product_file_embed_ids
          next if foreign_ids.empty?

          puts "[#{self.class.name}] rich_content=#{rich_content.id} entity=#{rich_content.entity_type}##{rich_content.entity_id} removing=#{foreign_ids.sort}"
          if dry_run
            cleaned += 1
            next
          end

          # The scan above can read a replica; remediate! re-checks under the lock, so a
          # candidate can turn out to be already clean. Count only what it rewrote.
          if remediate!(rich_content)
            cleaned += 1
          else
            puts "[#{self.class.name}] rich_content=#{rich_content.id} already clean under lock"
          end
        end
      end

      puts "[#{self.class.name}] done dry_run=#{dry_run} cleaned=#{cleaned}"
      { cleaned: }
    end

    private
      def remediate!(rich_content)
        ApplicationRecord.connected_to(role: :writing) do
          rich_content.with_lock do
            foreign_ids = rich_content.cross_product_file_embed_ids
            next false if foreign_ids.empty?

            rich_content.update!(description: RichContent.reject_file_embeds(rich_content.description, foreign_ids.to_set))

            entity = rich_content.entity
            if entity.is_a?(BaseVariant)
              stale_join_files = entity.product_files.where(id: foreign_ids)
              entity.product_files.delete(stale_join_files)
            end
            true
          end
        end
      end
  end
end
