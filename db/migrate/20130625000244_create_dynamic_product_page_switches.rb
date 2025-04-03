# frozen_string_literal: true

class CreateDynamicProductPageSwitches < ActiveRecord::Migration
  def change
    create_table :dynamic_product_page_switches do |t|
      t.string :name
      t.integer :default_switch_value
      t.integer :flags, default: 0, null: false

      t.timestamps
    end
  end
end
