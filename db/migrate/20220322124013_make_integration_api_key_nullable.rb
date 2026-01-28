# frozen_string_literal: true

class MakeIntegrationApiKeyNullable < ActiveRecord::Migration[4.2]
  def change
    change_column_null :integrations, :api_key, true
  end
end
