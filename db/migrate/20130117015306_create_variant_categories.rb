# frozen_string_literal: true

class CreateVariantCategories < ActiveRecord::Migration[4.2]
  def change
    create_table :variant_categories do |t|
      t.integer  :link_id
      t.datetime :deleted_at
    end
  end
end
