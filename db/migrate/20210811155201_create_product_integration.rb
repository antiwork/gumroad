# frozen_string_literal: true

class CreateProductIntegration < ActiveRecord::Migration[6.1]
  def change
    create_table :product_integrations do |t|
      t.bigint :product_id, null: false
      t.bigint :integration_id, null: false
      t.datetime :deleted_at

      t.timestamps
    end

    add_index :product_integrations, :integration_id
    add_index :product_integrations, :product_id
  end
end
