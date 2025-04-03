# frozen_string_literal: true

class AddUnsplashUrlToAssetPreview < ActiveRecord::Migration[6.1]
  def change
    add_column :asset_previews, :unsplash_url, :string
  end
end
