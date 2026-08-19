# frozen_string_literal: true

# Grows the dashboard sidebar as the user visits destinations that start out under "Everything else".
# Promotion is keyed on the person browsing, not the seller being browsed: it answers "have you used
# this". It records a visit and never grants access — the policy-gated rows keep their own gates in
# the nav, so a promotion for a destination this user cannot open renders nothing.
module PromotesDashboardNavItems
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
      # Seed only from the user's OWN store. Seeding a team member from whichever seller they happen
      # to be switched into would permanently credit them rows they never used, and it follows them
      # back to their own account — they earn rows by visiting instead.
      return unless logged_in_user && current_seller == logged_in_user

      logged_in_user.seed_promoted_nav_items!(seller: current_seller)
    rescue StandardError => e
      # Never fail a page over sidebar bookkeeping.
      ErrorNotifier.notify(e)
    end

    def promote_visited_nav_item
      return unless dashboard_nav_request?
      return unless response.successful?

      item = DashboardNav.item_for_path(request.path)
      return if item.nil?

      logged_in_user&.promote_nav_item!(item)
    rescue StandardError => e
      ErrorNotifier.notify(e)
    end

    def dashboard_nav_request?
      return false unless request.get?
      # Only a page render earns a row. The app's own fetch wrapper asks for JSON and does not set
      # X-Requested-With, so the format check — not xhr? — is what keeps its GETs out; Inertia and
      # browsers both resolve to html.
      return false unless request.format.html?
      # Inertia partial reloads re-fetch props for a page already on screen.
      return false if request.headers["X-Inertia-Partial-Data"].present?
      # The sidebar links prefetch on hover, and a prefetch is a real GET with X-Inertia. Overflow
      # rows opt out of prefetching for this reason (a click adopts the prefetch and sends nothing
      # of its own); this is the server-side half of that guard.
      return false if request.headers["Purpose"] == "prefetch"
      # Storefronts are served from seller subdomains and custom domains, where a slugged page can
      # collide with a dashboard path. Only the app's own hosts render this nav.
      return false unless GumroadDomainConstraint.matches?(request)

      DashboardNav.dashboard_path?(request.path)
    end
end
