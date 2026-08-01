# frozen_string_literal: true

# Which dashboard nav destinations this user has earned. See DashboardNav.
#
# Promotions live in their own table rather than under a users.json_data key because json_data is
# one serialized column with last-write-wins semantics: any request holding a stale copy of the
# user that later saves an unrelated JSON-backed setting would silently erase promotions recorded
# in between. Rows here are only ever inserted, so there is no read-modify-write to race and no
# lock to take.
module User::DashboardNavItems
  extend ActiveSupport::Concern

  # A seeded user with nothing earned must stay distinguishable from "never seeded", or the seed
  # scan would re-run on every page load. The marker is not promotable, so key readers never
  # surface it.
  SEEDED_MARKER = "seeded"

  included do
    has_many :dashboard_nav_promotions
  end

  def dashboard_nav_items_seeded?
    dashboard_nav_promotions.exists?
  end

  def promoted_nav_item_keys
    dashboard_nav_promotions.pluck(:nav_item) & DashboardNav::PROMOTABLE_ITEMS
  end

  # Records that this user has used `item`, returning the resulting key list. No-op when the item is
  # not promotable or is already recorded, so the common case does not write.
  def promote_nav_item!(item)
    item = item.to_s
    return promoted_nav_item_keys unless DashboardNav::PROMOTABLE_ITEMS.include?(item)
    return promoted_nav_item_keys if promoted_nav_item_keys.include?(item)

    record_nav_items([item])
  end

  def seed_promoted_nav_items!(seller:)
    return promoted_nav_item_keys if dashboard_nav_items_seeded?

    record_nav_items(DashboardNav.earned_items(user: self, seller:) + [SEEDED_MARKER])
  end

  private
    # insert_all skips rows the unique index already holds, so two requests seeding or promoting
    # concurrently both land whatever the other did not.
    def record_nav_items(items)
      DashboardNavPromotion.insert_all(items.map { |item| { user_id: id, nav_item: item } })
      promoted_nav_item_keys
    end
end
