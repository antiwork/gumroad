# frozen_string_literal: true

class MakeIntegrationApiKeyNullable < ActiveRecord::Migration[6.1]
  def change
    change_column_null :integrations, :api_key, true
  end
end
