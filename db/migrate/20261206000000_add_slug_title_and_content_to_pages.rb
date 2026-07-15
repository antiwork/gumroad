# frozen_string_literal: true

# First-class Pages: a seller (or product) can now have many pages instead of a
# single custom HTML blob. Existing rows keep a NULL slug and become the "root"
# page — the profile takeover for a user, the product page takeover for a
# product — so no data migration is needed. Additional pages get a slug, a
# title, and rich text content (or custom HTML pushed via the agent/CLI path).
class AddSlugTitleAndContentToPages < ActiveRecord::Migration[7.1]
  def change
    change_table :pages, bulk: true do |t|
      t.string :slug
      t.string :title
      t.text :content, size: :long

      # The old index enforced exactly one page per owner. Uniqueness is now
      # per (owner, slug); the single-root-page rule (slug NULL) is enforced in
      # the model since MySQL unique indexes allow multiple NULLs.
      t.remove_index [:pageable_type, :pageable_id], name: "index_pages_on_pageable", unique: true
      t.index [:pageable_type, :pageable_id, :slug], name: "index_pages_on_pageable_and_slug", unique: true
    end
  end
end
