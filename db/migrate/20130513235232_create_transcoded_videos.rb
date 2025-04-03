# frozen_string_literal: true

class CreateTranscodedVideos < ActiveRecord::Migration
  def change
    create_table :transcoded_videos do |t|
      t.references  :link
      t.string      :original_video_key
      t.string      :transcoded_video_key
      t.string      :transcoder_preset_key
      t.string      :job_id
      t.string      :state
      t.timestamps
    end

    add_index :transcoded_videos, :link_id
    add_index :transcoded_videos, :job_id
  end
end
