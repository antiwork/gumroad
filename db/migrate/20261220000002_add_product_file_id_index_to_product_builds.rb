# frozen_string_literal: true

# The buyer's download page and the seller's file picker both label a file by the build that owns
# it, so the lookup runs once per file. Without this index each of those is a full scan of the
# builds table.
class AddProductFileIdIndexToProductBuilds < ActiveRecord::Migration[8.1]
  def change
    add_index :product_builds, :product_file_id
  end
end
