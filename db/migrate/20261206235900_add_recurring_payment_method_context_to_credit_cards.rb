# frozen_string_literal: true

class AddRecurringPaymentMethodContextToCreditCards < ActiveRecord::Migration[7.1]
  # A recorded superseded version may own these columns, so rollback must preserve them.
  SUPERSEDED_VERSIONS = %w[
    20261206000015
    20261206000021
    20261206000023
    20261206000025
    20261206000027
    20261206000029
    20261206170803
  ].freeze

  COLUMNS = {
    payment_method_type: :string,
    stripe_account_id: :string,
    recurring_authorization_verified_at: :datetime,
    recurring_authorization_currency: :string,
    recurring_authorization_max_amount_cents: :integer
  }.freeze

  def up
    missing = COLUMNS.reject { |name, _| column_exists?(:credit_cards, name) }
    return if missing.empty?

    change_table :credit_cards, bulk: true do |t|
      missing.each { |name, type| t.column name, type }
    end
  end

  def down
    present = COLUMNS.keys.select { |name| column_exists?(:credit_cards, name) }
    return if present.empty?
    return if superseded_version_applied?

    change_table :credit_cards, bulk: true do |t|
      present.each { |name| t.remove name }
    end
  end

  private
    def superseded_version_applied?
      SUPERSEDED_VERSIONS.any? do |version|
        connection.select_value(
          ActiveRecord::Base.sanitize_sql_array(
            ["SELECT 1 FROM schema_migrations WHERE version = ? LIMIT 1", version]
          )
        ).present?
      end
    end
end
