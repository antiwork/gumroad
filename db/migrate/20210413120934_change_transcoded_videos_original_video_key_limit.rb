# frozen_string_literal: true

class ChangeTranscodedVideosOriginalVideoKeyLimit < ActiveRecord::Migration[6.1]
  def up
    change_column :transcoded_videos, :original_video_key, :string, limit: 1024
  end

  def down
    change_column :transcoded_videos, :original_video_key, :string
  end
end
