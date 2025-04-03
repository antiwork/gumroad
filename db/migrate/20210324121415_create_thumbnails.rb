# frozen_string_literal: true

class CreateThumbnails < ActiveRecord::Migration[6.1]
  def change
    create_table :thumbnails do |t|
      t.belongs_to :product, type: :integer, foreign_key: { to_table: :links }
      t.datetime :deleted_at
      t.string :guid

      t.timestamps
    end
  end
end
