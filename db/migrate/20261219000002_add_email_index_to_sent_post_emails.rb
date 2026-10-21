# frozen_string_literal: true

class AddEmailIndexToSentPostEmails < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # Built by hand in production: at this table's size the pt-osc copy cannot ride a deploy
  # (gumroad-private#1810), so there the deploy only records this version.
  def up
    return if Rails.env.production?

    add_index :sent_post_emails, :email, if_not_exists: true
  end

  def down
    return if Rails.env.production?

    remove_index :sent_post_emails, :email, if_exists: true
  end
end
