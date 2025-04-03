# frozen_string_literal: true

class RemoveForeignKeyConstraints < ActiveRecord::Migration[6.1]
  def up
    remove_foreign_key :devices, :users
    remove_foreign_key :featured_posts, :installments, column: :post_id
    remove_foreign_key :installment_events, :installments
    remove_foreign_key :large_sellers, :users
    remove_foreign_key :product_files_archives, :base_variants, column: :variant_id
    remove_foreign_key :product_reviews, :purchases
    remove_foreign_key :profile_tags, :tags
    remove_foreign_key :profile_tags, :users
    remove_foreign_key :thumbnails, :links
  end

  def down
    add_foreign_key "devices", "users", name: "_fk_rails_410b63ef65", on_delete: :cascade
    add_foreign_key "featured_posts", "installments", column: "post_id"
    add_foreign_key "installment_events", "installments", name: "_fk_rails_10f1699f91", on_delete: :cascade
    add_foreign_key "large_sellers", "users", name: "_fk_rails_a0fca89024", on_delete: :cascade
    add_foreign_key "product_files_archives", "base_variants", column: "variant_id", name: "_fk_rails_c054ae328a", on_delete: :cascade
    add_foreign_key "product_reviews", "purchases", name: "_fk_rails_3ec4cdfc41", on_delete: :cascade
    add_foreign_key "profile_tags", "tags", name: "_fk_rails_1c81d1ddab", on_delete: :cascade
    add_foreign_key "profile_tags", "users", name: "_fk_rails_657484ee2a", on_delete: :cascade
    add_foreign_key "thumbnails", "links", column: "product_id", name: "_fk_rails_f507e14b0c"
  end
end
