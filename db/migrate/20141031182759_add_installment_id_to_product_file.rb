# frozen_string_literal: true

class AddInstallmentIdToProductFile < ActiveRecord::Migration[4.2]
  def change
    add_column :product_files, :installment_id, :integer
    add_index :product_files, :installment_id
  end
end
