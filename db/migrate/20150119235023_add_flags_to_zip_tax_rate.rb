# frozen_string_literal: true

class AddFlagsToZipTaxRate < ActiveRecord::Migration
  def change
    add_column :zip_tax_rates, :flags, :integer, default: 0, null: false
  end
end
