# frozen_string_literal: true

class CreateBaseVariantIntegration < ActiveRecord::Migration[6.1]
  def change
    create_table :base_variant_integrations do |t|
      t.bigint :base_variant_id, null: false
      t.bigint :integration_id, null: false
      t.datetime :deleted_at

      t.timestamps
    end

    add_index :base_variant_integrations, :integration_id
    add_index :base_variant_integrations, :base_variant_id
  end
end
