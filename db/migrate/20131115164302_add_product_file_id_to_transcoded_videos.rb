# frozen_string_literal: true

class AddProductFileIdToTranscodedVideos < ActiveRecord::Migration
  def change
    add_column :transcoded_videos, :product_file_id, :integer
  end
end
