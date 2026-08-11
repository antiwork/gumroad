# frozen_string_literal: true

class AddUniqueIndexToAffiliatesLinks < ActiveRecord::Migration[7.1]
  # Deployed via pt-online-schema-change, which copies rows with INSERT IGNORE:
  # any (affiliate_id, link_id) pair still duplicated at migration time loses
  # rows silently instead of failing. Verify zero duplicate pairs in production
  # immediately before merging (gumroad-private#2067).
  def up
    return if index_exists?(:affiliates_links, [:affiliate_id, :link_id], name: :index_affiliates_links_on_affiliate_id_and_link_id)

    add_index :affiliates_links, [:affiliate_id, :link_id], unique: true, name: :index_affiliates_links_on_affiliate_id_and_link_id
  end

  def down
    return unless index_exists?(:affiliates_links, [:affiliate_id, :link_id], name: :index_affiliates_links_on_affiliate_id_and_link_id)

    remove_index :affiliates_links, name: :index_affiliates_links_on_affiliate_id_and_link_id
  end
end
