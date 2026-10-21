# frozen_string_literal: true

class AddApplicationIdIndexesToOauthCredentials < ActiveRecord::Migration[8.1]
  COLUMNS = [:application_id, :revoked_at].freeze

  # mark_deleted! revokes by application_id under the application row lock; without these the
  # sweep scanned and next-key locked the whole table. Each index is added only if missing: the
  # version is recorded after the whole migration, so a run that added one index and then failed
  # has to be finishable by a rerun.
  def up
    add_index(:oauth_access_grants, COLUMNS) unless index_exists?(:oauth_access_grants, COLUMNS)
    add_index(:oauth_access_tokens, COLUMNS) unless index_exists?(:oauth_access_tokens, COLUMNS)
  end

  def down
    remove_index(:oauth_access_grants, COLUMNS) if index_exists?(:oauth_access_grants, COLUMNS)
    remove_index(:oauth_access_tokens, COLUMNS) if index_exists?(:oauth_access_tokens, COLUMNS)
  end
end
