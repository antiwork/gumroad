# frozen_string_literal: true

class ChangeMediaLocationIdsToBigint < ActiveRecord::Migration[6.1]
  def up
    change_table :media_locations, bulk: true do |t|
      t.change :id, :bigint, null: false, unique: true, auto_increment: true
      t.change :product_file_id, :bigint
      t.change :url_redirect_id, :bigint
      t.change :purchase_id, :bigint
      t.change :link_id, :bigint
    end
  end

  def down
    change_table :media_locations, bulk: true do |t|
      t.change :id, :integer, null: false, unique: true, auto_increment: true
      t.change :product_file_id, :integer
      t.change :url_redirect_id, :integer
      t.change :purchase_id, :integer
      t.change :link_id, :integer
    end
  end
end
