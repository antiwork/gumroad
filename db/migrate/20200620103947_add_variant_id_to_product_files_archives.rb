# frozen_string_literal: true

class AddVariantIdToProductFilesArchives < ActiveRecord::Migration
  def change
    add_reference :product_files_archives, :variant, index: true
    add_foreign_key :product_files_archives, :base_variants, column: :variant_id, on_delete: :cascade
  end
end
