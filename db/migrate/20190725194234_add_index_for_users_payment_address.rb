# frozen_string_literal: true

class AddIndexForUsersPaymentAddress < ActiveRecord::Migration
  def up
    add_index :users, [:payment_address, :user_risk_state]
  end

  def down
    remove_index :users, [:payment_address, :user_risk_state]
  end
end
