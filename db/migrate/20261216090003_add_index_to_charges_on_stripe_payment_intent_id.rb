# frozen_string_literal: true

class AddIndexToChargesOnStripePaymentIntentId < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  SUPERSEDED_VERSION = "20260921212737"

  def up
    return if index_exists?(:charges, :stripe_payment_intent_id)

    # InnoDB's primary-key suffix supports the fallback's latest-id ordering.
    add_index :charges, :stripe_payment_intent_id
  end

  def down
    # Branch databases may have applied this index before the migration was renumbered.
    return if connection.select_value(
      ActiveRecord::Base.sanitize_sql_array(
        ["SELECT 1 FROM schema_migrations WHERE version = ? LIMIT 1", SUPERSEDED_VERSION]
      )
    ).present?
    return unless index_exists?(:charges, :stripe_payment_intent_id)

    remove_index :charges, :stripe_payment_intent_id
  end
end
