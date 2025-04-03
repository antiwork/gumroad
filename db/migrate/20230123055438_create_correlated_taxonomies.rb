# frozen_string_literal: true

class CreateCorrelatedTaxonomies < ActiveRecord::Migration[7.0]
  def change
    create_table :correlated_taxonomies do |t|
      t.references :taxonomy, index: { unique: true }, null: false
      t.json :related_taxonomy_ids, null: false
      t.timestamps
    end
  end
end
