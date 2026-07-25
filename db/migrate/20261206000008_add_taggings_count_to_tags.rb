# frozen_string_literal: true

class AddTaggingsCountToTags < ActiveRecord::Migration[7.1]
  def change
    # Deliberately NOT `change_table bulk: true`: fusing the column add with the
    # index build makes MySQL do a single INPLACE table rebuild, whereas adding the
    # column on its own is an INSTANT operation and only the index build has to
    # touch the table. Two cheaper statements beat one expensive one on a table this
    # size (~728K rows).
    add_column :tags, :taggings_count, :integer, default: 0, null: false

    # Tag autocomplete filters by name prefix and ranks by popularity. This
    # composite index can't serve the popularity ORDER BY directly (name is a range
    # condition, so MySQL still does a top-N filesort of the prefix matches), but it
    # narrows that sort to narrow index tuples instead of joining and counting
    # product_taggings on every keystroke. Measured worst case in production (a
    # one-character prefix matching ~67K of ~728K tags): under half a second cold
    # and sub-millisecond warm, vs ~5 seconds for the old JOIN + GROUP BY query.
    add_index :tags, [:name, :taggings_count]

    # index_tags_on_name is now a redundant left-prefix of the composite above: any
    # lookup it served (name equality, or the LIKE 'prefix%' range that autocomplete
    # uses) is served by (name, taggings_count) at the same cost. Dropping it saves
    # the write amplification and space of maintaining a duplicate index.
    remove_index :tags, :name
  end
end
