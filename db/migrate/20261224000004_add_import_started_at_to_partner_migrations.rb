# frozen_string_literal: true

class AddImportStartedAtToPartnerMigrations < ActiveRecord::Migration[8.1]
  def change
    add_column :partner_migrations, :import_started_at, :datetime
  end
end
