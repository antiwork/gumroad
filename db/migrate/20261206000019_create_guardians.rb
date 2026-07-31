# frozen_string_literal: true

class CreateGuardians < ActiveRecord::Migration[7.1]
  # Renumbered from 20261206000015 after that version was already recorded in production's
  # schema_migrations, so db:migrate now runs this migration against databases that already have
  # the table. up leaves an existing table alone; down refuses to drop a table this migration never
  # created, which is why this is an explicit up/down pair rather than a reversible change.
  SUPERSEDED_VERSION = "20261206000015"

  def up
    create_table :guardians, if_not_exists: true do |t|
      t.bigint :user_id, null: false, index: true

      t.string :first_name
      t.string :last_name
      t.string :email
      t.string :phone
      t.date :date_of_birth

      t.string :street_address
      t.string :city
      t.string :state
      t.string :zip_code
      t.string :country
      t.string :country_code
      t.string :nationality

      t.binary :individual_tax_id

      t.string :stripe_person_id, index: { unique: true }
      t.boolean :stripe_tos_accepted, default: false, null: false
      t.string :stripe_tos_ip
      t.datetime :stripe_tos_accepted_at

      t.datetime :deleted_at

      t.timestamps
    end
  end

  def down
    return unless table_exists?(:guardians)
    # Where the old version is still recorded, the table and every guardian row in it belong to that
    # migration, and rolling this one back must leave them in place. The version numbers alone cannot
    # prove ownership — the collision this branch fixes means 15 may instead have been the
    # presentment migration — so this errs towards keeping the table. A rollback that leaves an
    # unused table behind costs nothing; one that drops it loses data.
    return if superseded_version_applied?

    drop_table :guardians
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
