# frozen_string_literal: true

class CreateCredits < ActiveRecord::Migration
  def change
    create_table :credits do |t|
      t.integer :user_id
      t.integer :amount_cents
      t.integer :balance_id
      t.timestamps
    end
  end
end
