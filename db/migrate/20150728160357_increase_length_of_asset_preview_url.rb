# frozen_string_literal: true

class IncreaseLengthOfAssetPreviewUrl < ActiveRecord::Migration
  def change
    change_column(:asset_previews, :attachment_file_name, :string, limit: 2000)
  end
end
