# frozen_string_literal: true

# The signed IDs that partners and creators saw before carry the row ID; a Nano ID does not.
class AddPublicIdToPartnerMigrations < ActiveRecord::Migration[8.1]
  # utf8mb4_bin still pads trailing spaces; utf8mb4_0900_bin compares the exact bytes.
  EXACT_COLLATION = "utf8mb4_0900_bin"

  class PartnerMigrationRow < ActiveRecord::Base
    self.table_name = "partner_migrations"
  end

  def up
    add_column :partner_migrations, :public_id, :string, limit: 21, collation: EXACT_COLLATION
    PartnerMigrationRow.where(public_id: nil).find_each { _1.update_columns(public_id: Nanoid.generate) }
    change_table :partner_migrations, bulk: true do |t|
      t.change :public_id, :string, limit: 21, null: false, collation: EXACT_COLLATION
      t.index :public_id, unique: true
    end
  end

  def down
    remove_column :partner_migrations, :public_id
  end
end
