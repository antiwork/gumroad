# frozen_string_literal: true

class AddUnsplashUrlToThumbnail < ActiveRecord::Migration[4.2]
  def change
    add_column :thumbnails, :unsplash_url, :string
  end
end
