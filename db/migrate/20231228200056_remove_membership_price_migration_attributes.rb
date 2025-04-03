# frozen_string_literal: true

class RemoveMembershipPriceMigrationAttributes < ActiveRecord::Migration[7.0]
  def up
    change_table :prices, bulk: true do |t|
      t.remove :archived_at
      t.remove :base_tier_price
    end
  end

  def down
    change_table :prices, bulk: true do |t|
      t.column :archived_at, :datetime
      t.column :base_tier_price, :boolean
    end
  end
end
