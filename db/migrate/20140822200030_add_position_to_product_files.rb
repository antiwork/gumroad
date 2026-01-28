# frozen_string_literal: true

class AddPositionToProductFiles < ActiveRecord::Migration[4.2]
  def change
    add_column :product_files, :position, :integer
  end
end
