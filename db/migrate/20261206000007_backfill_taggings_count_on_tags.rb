# frozen_string_literal: true

class BackfillTaggingsCountOnTags < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    # Populate the new counter cache from the existing join rows. Batched by
    # tag id so each UPDATE holds locks briefly instead of scanning the whole
    # product_taggings table in one statement.
    Tag.in_batches(of: 1_000) do |batch|
      execute <<~SQL.squish
        UPDATE tags
        SET taggings_count = (
          SELECT COUNT(*) FROM product_taggings WHERE product_taggings.tag_id = tags.id
        )
        WHERE tags.id IN (#{batch.pluck(:id).join(',')})
      SQL
    end
  end

  def down
    # The counter is derived data; nothing to restore.
  end
end
