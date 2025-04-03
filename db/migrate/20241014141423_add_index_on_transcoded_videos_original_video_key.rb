# frozen_string_literal: true

class AddIndexOnTranscodedVideosOriginalVideoKey < ActiveRecord::Migration[7.1]
  def change
    add_index :transcoded_videos, :original_video_key
  end
end
