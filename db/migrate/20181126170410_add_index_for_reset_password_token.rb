# frozen_string_literal: true

class AddIndexForResetPasswordToken < ActiveRecord::Migration[4.2]
  def change
    add_index :users, :reset_password_token
  end
end
