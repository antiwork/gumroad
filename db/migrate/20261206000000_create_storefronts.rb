# frozen_string_literal: true

# First slice of "multiple storefronts per account": an account (User) keeps login, identity, and
# payout details, while each storefront is a separately-named brand the account sells under. This
# creates the storefront records themselves plus the assignment of products to a storefront.
# Existing accounts are untouched — their current username/profile keeps working as-is, and
# storefronts are purely additive on top.
class CreateStorefronts < ActiveRecord::Migration[7.1]
  def change
    create_table :storefronts do |t|
      t.references :seller, null: false
      # The storefront's public handle: it resolves at <username>.gumroad.com and
      # gumroad.com/<username>, so it must be unique. Uniqueness against account usernames
      # (the users table) is enforced in the model since it spans two tables.
      t.string :username, null: false
      t.string :name
      t.text :bio
      # Soft delete (Deletable concern) so a removed storefront is recoverable and its
      # username can be audited.
      t.datetime :deleted_at

      t.timestamps
    end

    add_index :storefronts, :username, unique: true

    create_table :storefront_products do |t|
      t.references :storefront, null: false
      t.references :link, null: false

      t.timestamps
    end

    # A product belongs to at most one storefront. Products with no row here keep showing on
    # the account's main profile, which is how every existing product behaves.
    add_index :storefront_products, :link_id, unique: true
  end
end
