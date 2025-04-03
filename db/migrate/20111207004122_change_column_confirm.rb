# frozen_string_literal: true

class ChangeColumnConfirm < ActiveRecord::Migration
  def up
    rename_column :users, :email_verified_at, :confirmed_at
    add_column :users, :confirmation_token, :string
    add_column :users, :confirmation_sent_at, :datetime
  end

  def down
    rename_column :users, :confirmed_at, :email_verified_at
    remove_column :users, :confirmation_token
    remove_column :users, :confirmation_sent_at, :datetime
  end
end
