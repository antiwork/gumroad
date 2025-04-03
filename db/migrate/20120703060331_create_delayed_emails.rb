# frozen_string_literal: true

class CreateDelayedEmails < ActiveRecord::Migration
  def change
    create_table :delayed_emails do |t|
      t.integer :purchase_id

      t.timestamps
    end
  end
end
