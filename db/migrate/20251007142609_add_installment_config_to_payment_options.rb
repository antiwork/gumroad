# frozen_string_literal: true

# This migration adds snapshot columns to the payment_options table
# to fix a bug where customers were charged incorrect amounts when
# sellers changed their product's installment plan configuration.
#
# Background:
# When a customer subscribes to an installment plan, we need to remember
# the terms they agreed to (how many payments, how often). Previously we
# would look up the product's current installment plan every time we
# charged the customer. If the seller changed the product's config,
# the customer would be charged different amounts than they agreed to.
#
# Solution:
# We now snapshot the installment config at subscription time by copying
# the values into these new columns. This way we always know what the
# customer originally agreed to, regardless of future product changes.
#
class AddInstallmentConfigToPaymentOptions < ActiveRecord::Migration[7.1]
  def change
    # We're adding two columns that will store a snapshot of the installment
    # plan configuration at the moment the customer subscribes.
    #
    # Wrapped in Alterity.disable for development environment because:
    # - Development doesn't have pt-online-schema-change installed
    # - In production, Alterity will use pt-online-schema-change to add
    #   these columns without locking the table
    # - Safe to disable in dev since we have small datasets
    Alterity.disable do
      # How many installment payments the customer agreed to (e.g., 3)
      # This value is copied from ProductInstallmentPlan.number_of_installments
      # at subscription creation time and never changes after that.
      add_column :payment_options, :number_of_installments, :integer

      # How often the customer will be charged (e.g., "monthly")
      # This value is copied from ProductInstallmentPlan.recurrence
      # at subscription creation time and never changes after that.
      add_column :payment_options, :recurrence, :string
    end

    # Backfill existing installment plan payment options with their
    # current product configuration values. This is a one-time data
    # migration to populate the snapshot columns for subscriptions
    # that were created before this migration.
    #
    # Why backfill:
    # - Existing customers need the snapshot data too
    # - Without it, they'd fall back to the old buggy behavior
    # - Safe to do because we're just copying the current state
    #
    # The WHERE conditions ensure:
    # 1. Only copy for records that have an installment plan
    # 2. Only copy if the snapshot doesn't already exist (idempotent)
    reversible do |dir|
      dir.up do
        execute <<-SQL.squish
          UPDATE payment_options po
          INNER JOIN product_installment_plans pip
            ON po.product_installment_plan_id = pip.id
          SET po.number_of_installments = pip.number_of_installments,
              po.recurrence = pip.recurrence
          WHERE po.product_installment_plan_id IS NOT NULL
            AND po.number_of_installments IS NULL
        SQL
      end
    end
  end
end
