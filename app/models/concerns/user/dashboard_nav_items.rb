# frozen_string_literal: true

# Which dashboard nav destinations this user has earned. See DashboardNav.
#
# Own table rather than a users.json_data key: that column is one last-write-wins document, so a
# request holding a stale user would erase promotions recorded in between. Rows here are only
# inserted, so there is no read-modify-write to race and no lock to take.
module User::DashboardNavItems
  extend ActiveSupport::Concern

  # A seeded user with nothing earned must stay distinguishable from "never seeded", or the seed
  # scan would re-run on every page load. The marker is not promotable, so key readers never
  # surface it.
  SEEDED_MARKER = "seeded"

  # A concurrent seed or promote of the same user can deadlock on the unique index's
  # insert-intention lock, and InnoDB aborts one of the two statements arbitrarily. Re-running it is
  # safe — the statement rolls back whole and the upsert skips whatever the winner landed — and the
  # lock wait is not retried: InnoDB already spent its timeout on the page render by then.
  CONTENTION_RETRIES = 2
  CONTENTION_BASE_BACKOFF = 0.05

  included do
    has_many :dashboard_nav_promotions, dependent: :delete_all
  end

  # The keys are memoized per instance, so a reload has to drop them or a caller that reloads to
  # observe a write still sees the pre-write list.
  def reload(...)
    @loaded_nav_items = nil
    super
  end

  def dashboard_nav_items_seeded?
    loaded_nav_items.include?(SEEDED_MARKER)
  end

  # Read once per request. Every nav render asks for this several times, and `pluck` would go to
  # the database each time — the callbacks run on every dashboard page load.
  def promoted_nav_item_keys
    loaded_nav_items & DashboardNav::PROMOTABLE_ITEMS
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
    def loaded_nav_items
      @loaded_nav_items ||= dashboard_nav_promotions.pluck(:nav_item)
    end

    # insert_all skips rows the unique index already holds, so two requests seeding or promoting
    # concurrently both land whatever the other did not. It bypasses Active Record, so the memo is
    # ours to invalidate.
    def record_nav_items(items)
      return promoted_nav_item_keys if items.empty?

      attempts = 0
      begin
        DashboardNavPromotion.insert_all(items.map { |item| { user_id: id, nav_item: item } })
      rescue ActiveRecord::Deadlocked
        attempts += 1
        raise if attempts > CONTENTION_RETRIES

        # Jittered so two losers retrying against each other don't line up again.
        sleep(CONTENTION_BASE_BACKOFF * (2**(attempts - 1)) * (0.5 + Kernel.rand))
        retry
      end
      @loaded_nav_items = nil
      promoted_nav_item_keys
    end
end
