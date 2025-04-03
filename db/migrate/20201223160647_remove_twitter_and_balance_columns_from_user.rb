# frozen_string_literal: true

class RemoveTwitterAndBalanceColumnsFromUser < ActiveRecord::Migration[6.0]
  def up
    change_table :users do |t|
      t.remove :twitter_verified, :twitter_location, :balance_cents
    end
  end

  def down
    change_table :users do |t|
      t.string :twitter_verified
      t.string :twitter_location
      t.integer :balance_cents, default: 0
    end
  end
end
