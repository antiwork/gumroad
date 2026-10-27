# frozen_string_literal: true

# The signed IDs that partners and creators saw before carry the row ID; a Nano ID does not.
#
# MySQL commits each ALTER, so a run that stops partway leaves the column, and maybe some IDs, behind.
# up continues from there: it keeps every valid ID already assigned and fills in only the missing ones.
class AddPublicIdToPartnerMigrations < ActiveRecord::Migration[8.1]
  # utf8mb4_bin still pads trailing spaces; utf8mb4_0900_bin compares the exact bytes.
  EXACT_COLLATION = "utf8mb4_0900_bin"
  INDEX_NAME = "index_partner_migrations_on_public_id"
  PUBLIC_ID_LENGTH = 21
  PUBLIC_ID_FORMAT = /\A[A-Za-z0-9_-]{#{PUBLIC_ID_LENGTH}}\z/

  class PartnerMigrationRow < ActiveRecord::Base
    self.table_name = "partner_migrations"
  end

  def up
    PartnerMigrationRow.reset_column_information
    column = connection.columns(:partner_migrations).find { _1.name == "public_id" }
    if column.nil?
      add_column :partner_migrations, :public_id, :string, limit: PUBLIC_ID_LENGTH, collation: EXACT_COLLATION
    elsif [column.sql_type, column.collation] != ["varchar(#{PUBLIC_ID_LENGTH})", EXACT_COLLATION]
      raise "partner_migrations.public_id exists as #{column.sql_type} #{column.collation}, not varchar(#{PUBLIC_ID_LENGTH}) #{EXACT_COLLATION}"
    end

    index = connection.indexes(:partner_migrations).find { _1.name == INDEX_NAME }
    raise "Index #{INDEX_NAME} exists but is not a unique index on public_id" if index && !(index.unique && index.columns == ["public_id"])

    assigned = PartnerMigrationRow.where.not(public_id: nil).pluck(:public_id)
    raise "partner_migrations has public_id values that are not Nano IDs" if assigned.grep_v(PUBLIC_ID_FORMAT).any?
    raise "partner_migrations has duplicate public_id values" if assigned.uniq.size != assigned.size

    PartnerMigrationRow.where(public_id: nil).find_each { _1.update_columns(public_id: Nanoid.generate) }

    return if column&.null == false && index

    change_table :partner_migrations, bulk: true do |t|
      t.change :public_id, :string, limit: PUBLIC_ID_LENGTH, null: false, collation: EXACT_COLLATION if column.nil? || column.null
      t.index :public_id, unique: true unless index
    end
  end

  def down
    remove_column :partner_migrations, :public_id
  end
end
