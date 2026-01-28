# frozen_string_literal: true

class AddBackgroundImageUrlToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :background_image_url, :string
  end
end
