# frozen_string_literal: true

class AddBackgroundImageUrlToUsers < ActiveRecord::Migration
  def change
    add_column :users, :background_image_url, :string
  end
end
