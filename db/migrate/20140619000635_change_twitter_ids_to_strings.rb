# frozen_string_literal: true

class ChangeTwitterIdsToStrings < ActiveRecord::Migration
  def up
    change_column :twitter_merchants, :twitter_assigned_merchant_id, :string
  end

  def down
    change_column :twitter_merchants, :twitter_assigned_merchant_id, :integer, limit: 8
  end
end
