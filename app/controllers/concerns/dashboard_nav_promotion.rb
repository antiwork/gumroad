# frozen_string_literal: true

# Grows the dashboard sidebar as the user visits destinations that start out under "Everything else".
# Promotion is keyed on the person browsing, not the seller being browsed: it answers "have you used
# this", and each promoted row still passes its own policy check before the nav renders it — so a
# promotion recorded for a destination this user can no longer open renders nothing.
module DashboardNavPromotion
  extend ActiveSupport::Concern

  included do
    # Seeding has to happen before the nav renders, or an existing seller landing on Home watches
    # their store's earned rows sit in the overflow for one page.
    before_action :seed_dashboard_nav_items
    # Promotion happens after, so a page the action ended up refusing is not credited. The nav pins
    # the row for the page being viewed regardless of its promotion state, so the seller still sees it
    # rise out of "Everything else" on this same render rather than the next one.
    after_action :promote_visited_nav_item
  end

  private
    def seed_dashboard_nav_items
      return unless dashboard_nav_request?

      logged_in_user&.seed_promoted_nav_items!(seller: current_seller)
    rescue ActiveRecord::ActiveRecordError => e
      # Never fail a page over sidebar bookkeeping.
      ErrorNotifier.notify(e)
    end

    def promote_visited_nav_item
      return unless dashboard_nav_request?
      return unless response.successful?

      item = DashboardNav.item_for_path(request.path)
      return if item.nil?

      logged_in_user&.promote_nav_item!(item)
    rescue ActiveRecord::ActiveRecordError => e
      ErrorNotifier.notify(e)
    end

    def dashboard_nav_request?
      return false unless request.get?
      return false if request.xhr?
      return false if impersonating?
      # Storefronts are served from seller subdomains and custom domains, where a slugged page can
      # collide with a dashboard path. Only the app's own hosts render this nav.
      return false unless GumroadDomainConstraint.matches?(request)

      DashboardNav.dashboard_path?(request.path)
    end
end
