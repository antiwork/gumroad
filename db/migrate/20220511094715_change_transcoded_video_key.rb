# frozen_string_literal: true

class ChangeTranscodedVideoKey < ActiveRecord::Migration[6.1]
  def up
    change_column :transcoded_videos, :transcoded_video_key, :string, limit: 2048
  end

  def down
    change_column :transcoded_videos, :transcoded_video_key, :string
  end
end
