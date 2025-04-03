# frozen_string_literal: true

class AddBanQueuedToUsers < ActiveRecord::Migration
  def change
    add_column :users, :ban_queued, :boolean
  end
end
