# frozen_string_literal: true

class AddApplicationIdIndexesToOauthCredentials < ActiveRecord::Migration[8.1]
  # mark_deleted! revokes by application_id under the application row lock; without these the
  # sweep scanned and next-key locked the whole table.
  def change
    add_index :oauth_access_grants, [:application_id, :revoked_at]
    add_index :oauth_access_tokens, [:application_id, :revoked_at]
  end
end
