# frozen_string_literal: true

class AddTaggingsCountToTags < ActiveRecord::Migration[7.1]
  def change
    # All three alterations go in ONE `change_table bulk: true` on purpose.
    #
    # This repo runs migrations through Percona's pt-online-schema-change (see
    # config/initializers/alterity.rb), which copies the whole table for every
    # ALTER it executes. MySQL's INSTANT/INPLACE optimisations never come into
    # play, so splitting these into separate statements would mean three full
    # copies of a ~728K-row table instead of one. Rails/BulkChangeTable enforces
    # this, and it is right to.
    change_table :tags, bulk: true do |t|
      t.integer :taggings_count, default: 0, null: false

      # Tag autocomplete filters by name prefix and ranks by popularity. This
      # composite index can't serve the popularity ORDER BY directly (name is a
      # range condition, so MySQL still does a top-N filesort of the prefix
      # matches), but it narrows that sort to narrow index tuples instead of
      # joining and counting product_taggings on every keystroke. Measured worst
      # case in production (a one-character prefix matching ~67K of ~728K tags):
      # under half a second cold and sub-millisecond warm, vs ~5 seconds for the
      # old JOIN + GROUP BY query.
      t.index [:name, :taggings_count]

      # index_tags_on_name becomes a redundant left-prefix of the composite
      # above: every lookup it served — name equality, or the LIKE 'prefix%'
      # range that autocomplete uses — is served by (name, taggings_count) at
      # the same cost. Keeping it would only cost write amplification and space.
      t.remove_index :name
    end
  end
end
