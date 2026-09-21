# frozen_string_literal: true

class AddMcpResourceBindingToOauthTables < ActiveRecord::Migration[8.1]
  def change
    add_column :oauth_applications, :mcp_dynamic_client, :boolean, default: false, null: false
    add_column :oauth_access_grants, :resource, :string
    add_column :oauth_access_tokens, :resource, :string
  end
end
