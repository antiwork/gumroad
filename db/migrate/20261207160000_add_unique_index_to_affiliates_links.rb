# frozen_string_literal: true

class AddUniqueIndexToAffiliatesLinks < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  # affiliates_links had no composite unique index, so racing INSERTs bypassed
  # the model's uniqueness validation and accumulated 2,816 duplicate
  # (affiliate_id, link_id) pairs in production (gumroad-private#2067). #7167
  # serialized the writes and the Onetime::DeduplicateProductAffiliates passes
  # removed the existing duplicates; the index makes the state unrepresentable.
  #
  # Deployed via pt-online-schema-change, which copies rows with INSERT IGNORE:
  # any pair still duplicated at migration time loses rows silently instead of
  # failing. Production must be re-verified to hold zero duplicate pairs
  # immediately before this merges.
  #
  # The single-column affiliate_id index stays even though this index covers it
  # as a leftmost prefix; dropping it is a separate decision.
  def up
    return if index_exists?(:affiliates_links, [:affiliate_id, :link_id], name: :index_affiliates_links_on_affiliate_id_and_link_id)

    add_index :affiliates_links, [:affiliate_id, :link_id], unique: true, name: :index_affiliates_links_on_affiliate_id_and_link_id
  end

  def down
    return unless index_exists?(:affiliates_links, [:affiliate_id, :link_id], name: :index_affiliates_links_on_affiliate_id_and_link_id)

    remove_index :affiliates_links, name: :index_affiliates_links_on_affiliate_id_and_link_id
  end
end
