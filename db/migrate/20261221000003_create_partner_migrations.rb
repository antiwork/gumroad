# frozen_string_literal: true

class CreatePartnerMigrations < ActiveRecord::Migration[8.1]
  # Renumbered, so a database that ran the superseded version already has this table. up keeps that
  # table only if it has the shape this migration and the later partner migrations give it, and never
  # changes it. down keeps the table while it has rows or the superseded version is recorded.
  SUPERSEDED_VERSION = "20261220000003"
  TABLE_COLLATION = "utf8mb4_unicode_ci"
  # name => [sql_type, null, default]
  COLUMNS = {
    "id" => ["bigint", false, nil],
    "oauth_application_id" => ["int", false, nil],
    "external_user_id" => ["varchar(255)", false, nil],
    "code_digest" => ["varchar(255)", false, nil],
    "products" => ["json", false, nil],
    "results" => ["json", true, nil],
    "status" => ["varchar(255)", false, "pending"],
    "user_id" => ["bigint", true, nil],
    "expires_at" => ["datetime(6)", false, nil],
    "claimed_at" => ["datetime(6)", true, nil],
    "completed_at" => ["datetime(6)", true, nil],
    "failure_reason" => ["varchar(255)", true, nil],
    "created_at" => ["datetime(6)", false, nil],
    "updated_at" => ["datetime(6)", false, nil],
  }.freeze
  # name => [columns, unique]
  INDEXES = {
    "index_partner_migrations_on_code_digest" => [["code_digest"], true],
    "index_partner_migrations_on_application_and_external_user" => [["oauth_application_id", "external_user_id"], false],
    "index_partner_migrations_on_user_id" => [["user_id"], false],
  }.freeze
  # From 20261221000004 to 20261221000006, which check their own changes.
  EXTERNAL_USER_ID_COLLATIONS = [TABLE_COLLATION, "utf8mb4_0900_bin"].freeze
  LATER_COLUMNS = %w[notified_at notification_failed_email public_id].freeze
  LATER_INDEXES = %w[index_partner_migrations_on_notified_at_and_completed_at index_partner_migrations_on_public_id].freeze

  def up
    if table_exists?(:partner_migrations)
      problems = existing_table_problems
      raise "partner_migrations exists in a shape this migration does not create: #{problems.join("; ")}" if problems.any?

      return
    end

    create_table :partner_migrations do |t|
      t.integer :oauth_application_id, null: false
      t.string :external_user_id, null: false
      t.string :code_digest, null: false
      t.json :products, null: false
      t.json :results
      t.string :status, null: false, default: "pending"
      t.bigint :user_id
      t.datetime :expires_at, null: false
      t.datetime :claimed_at
      t.datetime :completed_at
      t.string :failure_reason
      t.timestamps

      t.index :code_digest, unique: true
      t.index [:oauth_application_id, :external_user_id], name: "index_partner_migrations_on_application_and_external_user"
      t.index :user_id
    end
  end

  def down
    return unless table_exists?(:partner_migrations)
    raise ActiveRecord::IrreversibleMigration, "partner_migrations has rows" if select_value("SELECT 1 FROM partner_migrations LIMIT 1").present?
    return if superseded_version_applied?

    drop_table :partner_migrations
  end

  private
    def existing_table_problems
      columns = connection.columns(:partner_migrations).index_by(&:name)
      indexes = connection.indexes(:partner_migrations).index_by(&:name)

      problems = COLUMNS.filter_map do |name, expected|
        column = columns[name]
        next "#{name} is missing" if column.nil?
        next "#{name} is #{[column.sql_type, column.null, column.default].inspect}" if [column.sql_type, column.null, column.default] != expected
        next unless column.sql_type.start_with?("varchar")

        collations = name == "external_user_id" ? EXTERNAL_USER_ID_COLLATIONS : [TABLE_COLLATION]
        "#{name} has collation #{column.collation}" unless collations.include?(column.collation)
      end
      problems << "id is not the auto-increment primary key" unless connection.primary_key(:partner_migrations) == "id" && columns["id"]&.auto_increment?
      problems.concat((columns.keys - COLUMNS.keys - LATER_COLUMNS).map { "unexpected column #{_1}" })
      problems.concat(INDEXES.filter_map do |name, (index_columns, unique)|
        index = indexes[name]
        "index #{name} is missing or different" unless index && index.columns == index_columns && index.unique == unique
      end)
      problems.concat((indexes.keys - INDEXES.keys - LATER_INDEXES).map { "unexpected index #{_1}" })
    end

    def superseded_version_applied?
      connection.select_value(
        ActiveRecord::Base.sanitize_sql_array(
          ["SELECT 1 FROM schema_migrations WHERE version = ? LIMIT 1", SUPERSEDED_VERSION]
        )
      ).present?
    end
end
