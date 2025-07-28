# frozen_string_literal: true

class AddTaxInclusiveToLinks < ActiveRecord::Migration[6.1]
  def change
    add_column :links, :tax_inclusive, :boolean, default: true, null: false
    
    # Set existing records to false to maintain current tax-exclusive behavior
    reversible do |dir|
      dir.up do
        execute "UPDATE links SET tax_inclusive = false"
      end
    end
    
    # Add index for potential performance queries on tax_inclusive
    add_index :links, :tax_inclusive
  end
end