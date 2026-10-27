# frozen_string_literal: true

class AddNotifiedAtToPartnerMigrations < ActiveRecord::Migration[8.1]
  def change
    add_column :partner_migrations, :notified_at, :datetime # rubocop:disable Rails/BulkChangeTable -- Keep ADD COLUMN eligible for ALGORITHM=INSTANT.
    add_column :partner_migrations, :notification_failed_email, :string
    add_index :partner_migrations, [:notified_at, :completed_at]
  end
end
