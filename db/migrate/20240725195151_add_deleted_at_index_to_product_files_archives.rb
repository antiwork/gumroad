# frozen_string_literal: true

class AddDeletedAtIndexToProductFilesArchives < ActiveRecord::Migration[7.1]
  def up
    change_table :product_files_archives, bulk: true do |t|
      t.index :deleted_at

      t.change :id, :bigint, null: false, auto_increment: true
      t.change :link_id, :bigint
      t.change :installment_id, :bigint
      t.change :variant_id, :bigint
      t.change :deleted_at, :datetime, limit: 6
      t.change :deleted_from_cdn_at, :datetime, limit: 6
      t.change :created_at, :datetime, limit: 6
      t.change :updated_at, :datetime, limit: 6
    end
  end

  def down
    change_table :product_files_archives, bulk: true do |t|
      t.remove_index :deleted_at

      t.change :id, :int, null: false, auto_increment: true
      t.change :link_id, :int
      t.change :installment_id, :int
      t.change :variant_id, :bigint
      t.change :deleted_at, :datetime, precision: nil
      t.change :deleted_from_cdn_at, :datetime, precision: nil
      t.change :created_at, :datetime, precision: nil
      t.change :updated_at, :datetime, precision: nil
    end
  end
end
