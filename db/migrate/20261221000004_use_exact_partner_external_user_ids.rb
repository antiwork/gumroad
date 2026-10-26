# frozen_string_literal: true

# Partner user IDs are opaque, so "aB3x" and "Ab3X", or "id" and "id ", are different users. The tables'
# utf8mb4_unicode_ci ignores case, accents and trailing spaces, and utf8mb4_bin still pads spaces;
# utf8mb4_0900_bin compares the exact bytes.
class UseExactPartnerExternalUserIds < ActiveRecord::Migration[8.1]
  EXACT_COLLATION = "utf8mb4_0900_bin"
  TABLE_COLLATION = "utf8mb4_unicode_ci"
  TABLES = %i[partner_sellers partner_migrations].freeze

  def up
    TABLES.each { change_column _1, :external_user_id, :string, null: false, collation: EXACT_COLLATION }
  end

  def down
    # The looser comparison would merge distinct partner users, which partner_sellers' unique index
    # rejects. Check first, because MySQL commits each ALTER on its own.
    if partner_sellers_collide_under_table_collation?
      raise ActiveRecord::IrreversibleMigration, "partner_sellers has external_user_id values that are equal under #{TABLE_COLLATION}"
    end

    TABLES.each { change_column _1, :external_user_id, :string, null: false, collation: TABLE_COLLATION }
  end

  private
    def partner_sellers_collide_under_table_collation?
      select_value(<<~SQL).present?
        SELECT 1 FROM partner_sellers
        GROUP BY oauth_application_id, external_user_id COLLATE #{TABLE_COLLATION}
        HAVING COUNT(*) > 1
        LIMIT 1
      SQL
    end
end
