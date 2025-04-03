# frozen_string_literal: true

class AddEmailTypeToDelayedEmails < ActiveRecord::Migration
  def change
    add_column :delayed_emails, :email_type, :string
  end
end
