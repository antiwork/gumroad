# frozen_string_literal: true

class AddDeletedFromCdnAtToProductFiles < ActiveRecord::Migration
  def change
    add_column :product_files, :deleted_from_cdn_at, :datetime
  end
end
