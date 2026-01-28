# frozen_string_literal: true

class AddDeletedFromCdnAtToProductFiles < ActiveRecord::Migration[4.2]
  def change
    add_column :product_files, :deleted_from_cdn_at, :datetime
  end
end
