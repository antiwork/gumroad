# frozen_string_literal: true

class RemoveLinkIdFromAffiliates < ActiveRecord::Migration[7.0]
  def up
    remove_column :affiliates, :link_id
  end

  def down
    change_table :affiliates, bulk: true do |t|
      t.bigint :link_id
      t.index :link_id
    end
  end
end
