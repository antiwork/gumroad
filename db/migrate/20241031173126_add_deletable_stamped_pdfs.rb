# frozen_string_literal: true

class AddDeletableStampedPdfs < ActiveRecord::Migration[7.1]
  def up
    change_table :stamped_pdfs, bulk: true do |t|
      # new columns / indexes
      t.datetime :deleted_at, index: true
      t.datetime :deleted_from_cdn_at, index: true
      t.index :url
      t.index :created_at

      # standardization
      t.change :id, :bigint, null: false, auto_increment: true
      t.change :url_redirect_id, :bigint
      t.change :product_file_id, :bigint
      t.change :created_at, :datetime, limit: 6
      t.change :updated_at, :datetime, limit: 6
    end
  end

  def down
    change_table :stamped_pdfs, bulk: true do |t|
      t.remove :deleted_at
      t.remove :deleted_from_cdn_at
      t.remove_index :url
      t.remove_index :created_at

      t.change :id, :int, null: false, auto_increment: true
      t.change :url_redirect_id, :int
      t.change :product_file_id, :int
      t.change :created_at, :datetime, precision: nil
      t.change :updated_at, :datetime, precision: nil
    end
  end
end
