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

          cleaned += 1
          puts "[#{self.class.name}] rich_content=#{rich_content.id} entity=#{rich_content.entity_type}##{rich_content.entity_id} removing=#{foreign_ids.sort}"
          next if dry_run

          remediate!(rich_content, foreign_ids)
        end
      end

      puts "[#{self.class.name}] done dry_run=#{dry_run} cleaned=#{cleaned}"
      { cleaned: }
    end

    private
      def remediate!(rich_content, foreign_ids)
        ApplicationRecord.connection.stick_to_primary!
        ApplicationRecord.transaction do
          rich_content.update!(description: RichContent.reject_file_embeds(rich_content.description, foreign_ids.to_set))

          entity = rich_content.entity
          if entity.is_a?(BaseVariant)
            stale_join_files = entity.product_files.where(id: foreign_ids)
            entity.product_files.delete(stale_join_files)
          end
        end
      end
  end
end
