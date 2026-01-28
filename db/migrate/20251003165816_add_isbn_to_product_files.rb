# frozen_string_literal: true

class AddIsbnToProductFiles < ActiveRecord::Migration[4.2]
  def change
    add_column :product_files, :isbn, :string
  end
end
