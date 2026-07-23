# frozen_string_literal: true

class AddTaggingsCountToTags < ActiveRecord::Migration[7.1]
  def change
    change_table :tags, bulk: true do |t|
      t.integer :taggings_count, default: 0, null: false

      # Tag autocomplete filters by name prefix and ranks by popularity.
      # This composite index can't serve the popularity ORDER BY directly
      # (name is a range condition, so MySQL still does a top-N filesort of
      # the prefix matches), but it keeps that sort over narrow index tuples
      # instead of joining and counting product_taggings per keystroke.
      # Measured worst case in production (one-character prefix matching
      # ~67K of ~728K tags): under half a second cold and sub-millisecond
      # warm, vs ~5 seconds for the old JOIN + GROUP BY query.
      t.index [:name, :taggings_count]
    end
  end
end
