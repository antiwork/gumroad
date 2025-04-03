# frozen_string_literal: true

class ExpireTranscodedVideos < ActiveRecord::Migration[7.1]
  def up
    change_table :transcoded_videos, bulk: true do |t|
      t.datetime :deleted_at, index: true
      t.datetime :last_accessed_at, index: true
      t.index :transcoded_video_key
    end
  end

  def down
    change_table :transcoded_videos, bulk: true do |t|
      t.remove :deleted_at
      t.remove :last_accessed_at
      t.remove_index :transcoded_video_key
    end
  end
end
