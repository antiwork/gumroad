# frozen_string_literal: true

class IncreaseLengthOfAssetPreviewUrl < ActiveRecord::Migration[4.2]
  def change
    change_column(:asset_previews, :attachment_file_name, :string, limit: 2000)
  end
end
