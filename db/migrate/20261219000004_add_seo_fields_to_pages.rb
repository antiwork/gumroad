# frozen_string_literal: true

class AddSeoFieldsToPages < ActiveRecord::Migration[8.1]
  # Renumbered from this version, which main also took. A preview database that
  # ran the old number already has the columns, and they belong to that row.
  SUPERSEDED_VERSION = "20261219000003"

  def up
    return if column_exists?(:pages, :seo_title)

    change_table :pages, bulk: true do |t|
      t.string :seo_title
      t.text :seo_description
    end
  end

  # The old number now also belongs to another migration, so this keeps the
  # columns wherever that number is recorded.
  def down
    return if select_value("SELECT 1 FROM schema_migrations WHERE version = #{quote(SUPERSEDED_VERSION)}")

    change_table :pages, bulk: true do |t|
      t.remove :seo_title, :seo_description
    end
  end
end
