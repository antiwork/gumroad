# frozen_string_literal: true

class AddTaggingsCountToTags < ActiveRecord::Migration[7.1]
  def change
    change_table :tags, bulk: true do |t|
      t.integer :taggings_count, default: 0, null: false

      # Tag autocomplete filters by name prefix and ranks by popularity.
      # This composite index lets that query run as a pure index range scan
      # (no join against product_taggings, no GROUP BY per keystroke).
      t.index [:name, :taggings_count]
    end
  end
end
