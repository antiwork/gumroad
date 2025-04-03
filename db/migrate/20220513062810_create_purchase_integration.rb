# frozen_string_literal: true

class CreatePurchaseIntegration < ActiveRecord::Migration[6.1]
  def change
    create_table :purchase_integrations do |t|
      t.bigint :purchase_id, null: false
      t.bigint :integration_id, null: false
      t.datetime :deleted_at
      t.string :discord_user_id

      t.timestamps
    end

    add_index :purchase_integrations, :integration_id
    add_index :purchase_integrations, :purchase_id
  end
end
