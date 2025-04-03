# frozen_string_literal: true

class CreateDynamicProductPageSwitchAssignments < ActiveRecord::Migration
  def change
    create_table :dynamic_product_page_switch_assignments do |t|
      t.references :link
      t.references :dynamic_product_page_switch
      t.integer :switch_value
      t.datetime :deleted_at

      t.timestamps
    end

    add_index :dynamic_product_page_switch_assignments, [:link_id, :dynamic_product_page_switch_id], name: "index_dynamic_product_page_assignments_on_link_id_and_switch_id"
  end
end
