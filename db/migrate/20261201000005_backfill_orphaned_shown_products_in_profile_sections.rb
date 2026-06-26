# frozen_string_literal: true

# One-time cleanup for the leak fixed in Link#remove_from_profile_sections!.
# Before that fix, soft-deleting a product never stripped its id from
# SellerProfileProductsSection.shown_products, so sections kept pointing at
# dead product ids and rendered as empty containers the seller couldn't remove
# (issue gumroad-private#685). This strips every deleted product id out of the
# shown_products arrays. Forward-only; there is nothing meaningful to restore.
class BackfillOrphanedShownProductsInProfileSections < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    # json_data is a native MySQL `json` column, so AR auto-casts it to a Hash.
    # `seller_profile_sections` has an STI `type` column; disable inheritance on
    # the stub so AR loads every row as a plain record instead of trying to
    # resolve `type` (e.g. "SellerProfileProductsSection") to a subclass of this
    # anonymous class — which it isn't, raising ActiveRecord::SubclassNotFound.
    sections = Class.new(ActiveRecord::Base) do
      self.table_name = "seller_profile_sections"
      self.inheritance_column = :_type_disabled
    end

    # Use an anonymous AR stub for links too, rather than the live `Link` model.
    # A backfill migration must be reproducible years from now from a fresh
    # `db:migrate`; coupling it to the application model means a future rename,
    # default scope, or change to how `deleted_at` is interpreted would silently
    # alter what this one-time cleanup considers "alive". The stub pins the
    # behavior to the raw table + column as they exist at write time.
    links = Class.new(ActiveRecord::Base) do
      self.table_name = "links"
    end

    sections
      .where(type: "SellerProfileProductsSection")
      .find_each(batch_size: 500) do |section|
        data = section.json_data
        next unless data.is_a?(Hash)

        shown = data["shown_products"]
        next unless shown.is_a?(Array) && shown.present?

        alive_ids = links.where(id: shown, deleted_at: nil).pluck(:id).to_set
        cleaned = shown.select { |pid| alive_ids.include?(pid) }
        next if cleaned.length == shown.length

        section.update_columns(
          json_data: data.merge("shown_products" => cleaned),
          updated_at: Time.current
        )
      end
  end

  def down
    # No-op: removed ids referenced soft-deleted products and carried no value.
  end
end
