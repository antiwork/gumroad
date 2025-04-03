# frozen_string_literal: true

class AddMissingIndexesToUser < ActiveRecord::Migration[6.0]
  def change
    change_table :users do |t|
      t.index :current_sign_in_ip
      t.index :last_sign_in_ip
      t.index :account_created_ip
      t.index :user_risk_state
    end
  end
end
