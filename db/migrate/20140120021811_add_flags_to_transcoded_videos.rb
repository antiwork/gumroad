# frozen_string_literal: true

class AddFlagsToTranscodedVideos < ActiveRecord::Migration
  def change
    add_column :transcoded_videos, :flags, :integer, default: 0, null: false
  end
end
