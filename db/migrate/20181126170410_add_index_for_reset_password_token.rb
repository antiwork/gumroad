# frozen_string_literal: true

class AddIndexForResetPasswordToken < ActiveRecord::Migration
  def change
    add_index :users, :reset_password_token
  end
end
