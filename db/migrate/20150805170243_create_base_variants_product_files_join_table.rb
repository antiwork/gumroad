# frozen_string_literal: true

class CreateBaseVariantsProductFilesJoinTable < ActiveRecord::Migration[4.2]
  def change
    create_table :base_variants_product_files do |t|
      t.references :base_variant
      t.references :product_file
    end

    add_index :base_variants_product_files, :base_variant_id
    add_index :base_variants_product_files, :product_file_id
  end
end
