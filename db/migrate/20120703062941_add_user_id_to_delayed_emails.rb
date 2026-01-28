# frozen_string_literal: true

class AddUserIdToDelayedEmails < ActiveRecord::Migration[4.2]
  def change
    add_column :delayed_emails, :user_id, :integer
  end
end
