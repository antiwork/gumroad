# frozen_string_literal: true

class AddRetryStateToPartnerMigrations < ActiveRecord::Migration[8.1]
  def change
    change_table :partner_migrations, bulk: true do |t|
      t.integer :resumes_count, default: 0, null: false
      t.datetime :failure_notified_at
      t.index [:status, :updated_at]
    end
  end
end
