# frozen_string_literal: true

class CreateTaxonomyHierarchies < ActiveRecord::Migration[6.1]
  def change
    create_table :taxonomy_hierarchies, id: false do |t|
      t.bigint :ancestor_id, null: false
      t.bigint :descendant_id, null: false
      t.integer :generations, null: false
    end

    add_index :taxonomy_hierarchies, [:ancestor_id, :descendant_id, :generations],
              unique: true,
              name: "taxonomy_anc_desc_idx"

    add_index :taxonomy_hierarchies, [:descendant_id],
              name: "taxonomy_desc_idx"
  end
end
