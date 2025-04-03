# frozen_string_literal: true

class CreatePayments < ActiveRecord::Migration
  def change
    create_table :payments do |t|
      t.references :user
      t.string :status
      t.text :status_data
      t.float :amount

      t.timestamps
    end
    add_index :payments, :user_id
  end
end
