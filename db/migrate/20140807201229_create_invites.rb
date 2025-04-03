# frozen_string_literal: true

class CreateInvites < ActiveRecord::Migration
  def change
    create_table :invites do |t|
      t.integer :sender_id
      t.string :receiver_email
      t.integer :receiver_id
      t.string :invite_state

      t.timestamps
    end

    add_index :invites, [:sender_id]
    add_index :invites, [:receiver_id], unique: true
  end
end
