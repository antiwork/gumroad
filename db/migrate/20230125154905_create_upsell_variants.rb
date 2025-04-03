# frozen_string_literal: true

class CreateUpsellVariants < ActiveRecord::Migration[7.0]
  def change
    create_table :upsell_variants do |t|
      t.references :upsell, null: false
      t.references :selected_variant, null: false
      t.references :offered_variant, null: false
      t.datetime :deleted_at

      t.timestamps
    end
  end
end
