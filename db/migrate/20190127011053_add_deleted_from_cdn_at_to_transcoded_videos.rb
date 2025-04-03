# frozen_string_literal: true

class AddDeletedFromCdnAtToTranscodedVideos < ActiveRecord::Migration
  def change
    add_column :transcoded_videos, :deleted_from_cdn_at, :datetime
  end
end
