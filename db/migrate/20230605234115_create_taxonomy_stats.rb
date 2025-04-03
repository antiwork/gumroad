# frozen_string_literal: true

class CreateTaxonomyStats < ActiveRecord::Migration[7.0]
  def change
    create_table :taxonomy_stats do |t|
      t.references :taxonomy, null: false
      t.integer :creators_count, null: false, default: 0
      t.integer :products_count, null: false, default: 0
      t.integer :sales_count, null: false, default: 0
      t.timestamps
    end
  end
end
