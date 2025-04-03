# frozen_string_literal: true

class CreateRefunds < ActiveRecord::Migration
  def change
    create_table :refunds do |t|
      t.integer :amount_cents, default: 0
      t.integer :purchase_id
      t.timestamps
    end
  end
end
