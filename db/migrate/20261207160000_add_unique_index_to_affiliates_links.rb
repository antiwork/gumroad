# frozen_string_literal: true

class AddUniqueIndexToAffiliatesLinks < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  INDEX_NAME = :index_affiliates_links_on_affiliate_id_and_link_id
  COLUMNS = [:affiliate_id, :link_id].freeze

  # pt-online-schema-change copies with INSERT IGNORE, so duplicates must be
  # removed before this migration runs.
  def up
    return if index_exists?(:affiliates_links, COLUMNS, unique: true, name: INDEX_NAME)

    if index_name_exists?(:affiliates_links, INDEX_NAME)
      raise "Index #{INDEX_NAME} exists but does not match the required unique composite index"
    end

    add_index :affiliates_links, COLUMNS, unique: true, name: INDEX_NAME
  end

  def down
    return unless index_exists?(:affiliates_links, COLUMNS, unique: true, name: INDEX_NAME)

    remove_index :affiliates_links, name: INDEX_NAME
  end
end
