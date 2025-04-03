# frozen_string_literal: true

class RemoveResetPasswordIndexFromUsers < ActiveRecord::Migration
  def up
    remove_index "users", "reset_password_token"
  end

  def down
    add_index "users", "reset_password_token"
  end
end
