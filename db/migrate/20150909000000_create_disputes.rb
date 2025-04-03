# frozen_string_literal: true

class CreateDisputes < ActiveRecord::Migration
  def change
    create_table :disputes, options: "DEFAULT CHARACTER SET=utf8 COLLATE=utf8_unicode_ci" do |t|
      t.references :purchase
      t.string :charge_processor_id
      t.string :charge_processor_dispute_id
      t.string :reason
      t.string :state
      t.datetime :initiated_at
      t.datetime :closed_at
      t.datetime :formalized_at
      t.datetime :won_at
      t.datetime :lost_at
    end

    add_index :disputes, :purchase_id

    add_column :credits, :dispute_id, :integer

    add_index :credits, :dispute_id
  end
end
