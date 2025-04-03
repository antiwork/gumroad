# frozen_string_literal: true

class CreateIntegration < ActiveRecord::Migration[6.1]
  def change
    create_table :integrations do |t|
      t.string :api_key, null: false
      t.string :integration_type, null: false
      t.text :json_data

      t.timestamps
    end
  end
end
