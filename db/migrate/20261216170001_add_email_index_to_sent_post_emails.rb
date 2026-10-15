# frozen_string_literal: true

class AddEmailIndexToSentPostEmails < ActiveRecord::Migration[7.1]
  # Renumbered from 20261216160001 after main took a later version. The preview app may already
  # have run the old one, so both directions have to cope with the index being there.
  SUPERSEDED_VERSION = "20261216160001"
  INDEX_NAME = "index_sent_post_emails_on_email"

  disable_ddl_transaction!

  def up
    # The only other index is (post_id, email), so erasing one recipient's rows
    # across every seller's posts scans the table. 191 matches idx_audience_on_email.
    #
    # if_not_exists so the pt-osc copy can be run out of band ahead of the deploy
    # instead of inside it (gumroad-private#1810).
    add_index :sent_post_emails, :email, name: INDEX_NAME, length: 191, if_not_exists: true
  end

  def down
    # Where the superseded version is still recorded, the index belongs to that migration.
    return if superseded_version_applied?

    remove_index :sent_post_emails, name: INDEX_NAME, if_exists: true
  end

  private
    def superseded_version_applied?
      connection.select_value(
        ActiveRecord::Base.sanitize_sql_array(
          ["SELECT 1 FROM schema_migrations WHERE version = ? LIMIT 1", SUPERSEDED_VERSION]
        )
      ).present?
    end
end
