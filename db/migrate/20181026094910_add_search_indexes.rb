# frozen_string_literal: true

class AddSearchIndexes < ActiveRecord::Migration
  def change
    add_index :users, :name
    add_index :gifts, :giftee_email
    add_index :purchases, :full_name
    add_index :subscriptions, :cancelled_at
    add_index :subscriptions, :failed_at
  end
end
