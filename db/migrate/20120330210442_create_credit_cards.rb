# frozen_string_literal: true

class CreateCreditCards < ActiveRecord::Migration
  def change
    create_table :credit_cards do |t|
      t.string :card_type
      t.integer :expiry_month
      t.integer :expiry_year
      t.references :user
      t.string :stripe_id
      t.string :visual

      t.timestamps
    end
    add_index :credit_cards, :user_id
  end
end
