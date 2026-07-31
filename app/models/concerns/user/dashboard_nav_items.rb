# frozen_string_literal: true

# Which dashboard nav destinations this user has earned. See DashboardNav.
module User::DashboardNavItems
  JSON_DATA_KEY = "promoted_nav_items"

  # A seeded user with nothing earned stores [], which is a real answer and must be distinguishable
  # from "never seeded". attr_json_data_accessor cannot express that — its reader treats a blank value
  # as absent and hands back the default — so this reads the key's presence directly.
  def dashboard_nav_items_seeded?
    json_data.key?(JSON_DATA_KEY)
  end

  def promoted_nav_items
    json_data[JSON_DATA_KEY]
  end

  def promoted_nav_items=(items)
    set_json_data_for_attr(JSON_DATA_KEY, Array(items).map(&:to_s).uniq & DashboardNav::PROMOTABLE_ITEMS)
  end

  def promoted_nav_item_keys
    Array(promoted_nav_items).map(&:to_s) & DashboardNav::PROMOTABLE_ITEMS
  end

  # Records that this user has used `item`, returning the resulting key list. No-op when the item is
  # not promotable or is already recorded, so the common case does not write.
  def promote_nav_item!(item)
    item = item.to_s
    return promoted_nav_item_keys unless DashboardNav::PROMOTABLE_ITEMS.include?(item)
    return promoted_nav_item_keys if promoted_nav_item_keys.include?(item)

    merge_promoted_nav_items!([item])
  end

  def seed_promoted_nav_items!(seller:)
    return promoted_nav_item_keys if dashboard_nav_items_seeded?

    merge_promoted_nav_items!(DashboardNav.earned_items(user: self, seller:))
  end

  private
    # json_data is one column, so a blind write here would drop a concurrent write to any other
    # attribute in it. Re-read under the row lock and merge instead. Writes are rare (once per seed,
    # once per newly used destination), so the lock is not on any hot path.
    def merge_promoted_nav_items!(items)
      with_lock do
        reload
        self.promoted_nav_items = Array(promoted_nav_items) + items
        save!
        promoted_nav_item_keys
      end
    end
end
