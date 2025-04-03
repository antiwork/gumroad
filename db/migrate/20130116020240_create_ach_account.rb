# frozen_string_literal: true

class CreateAchAccount < ActiveRecord::Migration
  def change
    create_table :ach_accounts do |t|
      t.references :user
      t.string :routing_number
      t.binary :account_number
      t.string :state

      t.timestamps
    end
    add_index :ach_accounts, :user_id
  end
end
