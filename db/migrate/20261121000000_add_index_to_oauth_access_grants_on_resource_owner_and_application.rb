# frozen_string_literal: true

class AddIndexToOauthAccessGrantsOnResourceOwnerAndApplication < ActiveRecord::Migration[7.1]
  def change
    add_index :oauth_access_grants, [:resource_owner_id, :application_id]
  end
end
