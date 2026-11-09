# frozen_string_literal: true

class CreatePurchaseRefundRequests < ActiveRecord::Migration[7.1]
  # Renumbered from 20261226000001, which this branch's preview database ran with an older shape
  # of this table; up replaces that shape, and down keeps the table while the old number is recorded.
  SUPERSEDED_VERSION = "20261226000001"

  def up
    if table_exists?(:purchase_refund_requests)
      return if column_exists?(:purchase_refund_requests, :escalated_at)

      drop_table :purchase_refund_requests
    end
    create_table :purchase_refund_requests, charset: "utf8mb4", collation: "utf8mb4_unicode_ci" do |t|
      t.bigint :purchase_id, null: false
      t.string :email, null: false
      t.string :reason, null: false
      t.text :message
      t.datetime :escalated_at

      t.timestamps

      t.index :purchase_id, unique: true
      t.index %i[escalated_at created_at]
    end
  end

  def down
    return if superseded_version_recorded?

    drop_table :purchase_refund_requests, if_exists: true
  end

  private
    def superseded_version_recorded?
      connection.select_value(
        ActiveRecord::Base.sanitize_sql_array(
          ["SELECT 1 FROM schema_migrations WHERE version = ? LIMIT 1", SUPERSEDED_VERSION]
        )
      ).present?
    end
end
