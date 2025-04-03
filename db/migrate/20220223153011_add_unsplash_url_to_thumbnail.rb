# frozen_string_literal: true

class AddUnsplashUrlToThumbnail < ActiveRecord::Migration[6.1]
  def change
    add_column :thumbnails, :unsplash_url, :string
  end
end
