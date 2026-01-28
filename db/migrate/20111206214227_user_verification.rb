# frozen_string_literal: true

class UserVerification < ActiveRecord::Migration[4.2]
  def up
    add_column :users, :email_verified_at, :datetime
  end

  def down
    remove_column :users, :email_verified_at, :datetime
  end
end
