# frozen_string_literal: true

class AddProductFileIdToTranscodedVideos < ActiveRecord::Migration[4.2]
  def change
    add_column :transcoded_videos, :product_file_id, :integer
  end
end
