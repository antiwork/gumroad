# frozen_string_literal: true

class AddPositionToAssetPreviews < ActiveRecord::Migration
  def change
    add_column :asset_previews, :position, :integer
  end
end
