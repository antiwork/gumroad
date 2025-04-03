# frozen_string_literal: true

class PrepareBaseVariant < ActiveRecord::Migration
  def change
    rename_table :variants, :base_variants
    rename_table :purchases_variants, :base_variants_purchases
    rename_column :base_variants_purchases, :variant_id, :base_variant_id
    add_column :base_variants, :type, :string, default: "Variant"
    add_column :base_variants, :link_id, :integer

    create_table :skus_variants do |t|
      t.integer :variant_id
      t.integer :sku_id
    end

    add_index :skus_variants, :variant_id
    add_index :skus_variants, :sku_id
  end
end
