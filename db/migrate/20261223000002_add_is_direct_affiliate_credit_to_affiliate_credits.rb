# frozen_string_literal: true

class AddIsDirectAffiliateCreditToAffiliateCredits < ActiveRecord::Migration[8.1]
  # Renumbered from this version, which main also took. A preview database that ran the old number
  # already has the column, and it belongs to that row.
  SUPERSEDED_VERSION = "20261223000001"

  def up
    return if column_exists?(:affiliate_credits, :is_direct_affiliate_credit)

    add_column :affiliate_credits, :is_direct_affiliate_credit, :boolean, default: false, null: false
  end

  # The old number now also belongs to another migration, so this keeps the column wherever that
  # number is recorded.
  def down
    return unless column_exists?(:affiliate_credits, :is_direct_affiliate_credit)
    return if superseded_version_applied?

    remove_column :affiliate_credits, :is_direct_affiliate_credit
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
