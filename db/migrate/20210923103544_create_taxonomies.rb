# frozen_string_literal: true

class CreateTaxonomies < ActiveRecord::Migration[6.1]
  def change
    create_table :taxonomies do |t|
      t.string :name, null: false
      t.bigint :parent_id, index: true
    end
  end
end
