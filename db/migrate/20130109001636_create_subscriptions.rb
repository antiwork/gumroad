# frozen_string_literal: true

class CreateSubscriptions < ActiveRecord::Migration
  def change
    create_table :subscriptions do |t|
      t.integer     :link_id
      t.integer     :user_id
      t.datetime    :cancelled_at
      t.datetime    :failed_at
      t.timestamps
    end
  end
end
