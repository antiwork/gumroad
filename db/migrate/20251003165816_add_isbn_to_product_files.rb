# frozen_string_literal: true

class AddIsbnToProductFiles < ActiveRecord::Migration[7.1]
  def change
    Alterity.disable do
      add_column :product_files, :isbn, :string
    end
  end
end
