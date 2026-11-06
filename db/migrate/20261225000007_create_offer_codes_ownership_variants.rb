# frozen_string_literal: true

class CreateOfferCodesOwnershipVariants < ActiveRecord::Migration[7.1]
  # Renumbered from 20261225000006, which main's AI archive migration also took. A database that
  # ran the old number already has this table (and treats the archive as run; nothing reads those
  # tables). down keeps the table while that number is recorded, as on every database on main,
  # because it can't tell which migration created it.
  SUPERSEDED_VERSION = "20261225000006"

  def up
    return if table_exists?(:offer_codes_ownership_variants)

    create_table :offer_codes_ownership_variants do |t|
      t.bigint :offer_code_id, null: false
      t.bigint :variant_id, null: false

      t.timestamps

      t.index [:offer_code_id, :variant_id], unique: true, name: "index_offer_codes_ownership_variants_on_code_and_variant"
      t.index :variant_id
    end
  end

  def down
    return unless table_exists?(:offer_codes_ownership_variants)
    return if superseded_version_recorded?

    drop_table :offer_codes_ownership_variants
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
