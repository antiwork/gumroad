# frozen_string_literal: true

class CreateSxswMeetings < ActiveRecord::Migration
  def change
    create_table :sxsw_meetings do |t|
      t.string :email
      t.string :name
      t.integer :time_slot
      t.boolean :confirmed
      t.text :message
      t.string :guest_name
      t.string :guest_email

      t.timestamps
    end
  end
end
