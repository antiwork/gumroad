# frozen_string_literal: true

class AddUserRiskStateToUsers < ActiveRecord::Migration
  def up
    add_column :users, :user_risk_state, :string
  end

  def down
    remove_column :users, :user_risk_state
  end
end
