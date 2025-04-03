# frozen_string_literal: true

class CreateGifts < ActiveRecord::Migration
  def change
    create_table :gifts do |t|
      t.integer :giftee_purchase_id
      t.integer :gifter_purchase_id
      t.integer :link_id
      t.string :state
      t.string :gift_note
      t.string :giftee_email
      t.string :gifter_email

      t.timestamps
    end
  end
end
