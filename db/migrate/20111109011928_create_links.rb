# frozen_string_literal: true

class CreateLinks < ActiveRecord::Migration[7.1]
  def change
    create_table :links do |t|
      t.integer :user_id
      t.string :name
      t.string :unique_permalink
      t.string :url
      t.string :preview_url
      t.string :description
      t.float :price
      t.integer :number_of_paid_downloads
      t.integer :number_of_downloads
      t.integer :download_limit
      t.integer :number_of_views
      t.float :balance

      t.timestamps
    end
  end
end
