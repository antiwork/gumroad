# frozen_string_literal: true

class CreateTips < ActiveRecord::Migration[7.1]
  def change
    create_table :tips do |t|
      t.references :purchase, null: false
      t.integer :value_cents, null: false

      t.timestamps
    end
  end
end
