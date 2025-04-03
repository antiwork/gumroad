# frozen_string_literal: true

class CreateVariants < ActiveRecord::Migration
  def change
    create_table :variants do |t|
      t.integer :variant_category_id
      t.integer :price_difference_cents
      t.string  :name
    end

    add_index :variants, :variant_category_id
  end
end
