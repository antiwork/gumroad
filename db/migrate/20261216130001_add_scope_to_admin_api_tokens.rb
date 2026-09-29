# frozen_string_literal: true

class AddScopeToAdminApiTokens < ActiveRecord::Migration[7.1]
  def change
    add_column :admin_api_tokens, :scope, :string, limit: 32, null: false, default: "admin"
  end
end
