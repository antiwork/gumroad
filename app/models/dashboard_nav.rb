# frozen_string_literal: true

# The dashboard sidebar starts with a small set of destinations and grows as a seller uses the rest,
# which are reachable meanwhile under "Everything else". Item keys are shared with the client nav
# (app/javascript/components/client-components/Nav), so renaming one here needs the same rename there.
module DashboardNav
  extend self

  # Always rendered, in this order, for every seller.
  CORE_ITEMS = %w[home products sales payouts discover].freeze

  # Rendered only once promoted. A promoted item still passes through its own policy check in the
  # nav, so a promotion recorded for a destination the user cannot open renders nothing.
  PROMOTABLE_ITEMS = %w[agent profile pages collaborators checkout emails workflows analytics affiliates community library].freeze

  ITEMS = (CORE_ITEMS + PROMOTABLE_ITEMS).freeze

  # Dashboard paths that count as using a promotable destination.
  PATH_PREFIXES = {
    "/agent" => "agent",
    "/profile" => "profile",
    "/pages" => "pages",
    "/collaborators" => "collaborators",
    "/checkout" => "checkout",
    "/emails" => "emails",
    "/followers" => "emails",
    "/workflows" => "workflows",
    "/dashboard/sales" => "analytics",
    "/dashboard/audience" => "analytics",
    "/dashboard/utm_links" => "analytics",
    "/dashboard/churn" => "analytics",
    "/affiliates" => "affiliates",
    "/communities" => "community",
    "/library" => "library",
    "/wishlists" => "library",
    "/reviews" => "library",
  }.freeze

  # Paths that render the dashboard sidebar but promote nothing, either because the destination is
  # always in the core list or because it is reached from the pinned footer.
  CORE_PATH_PREFIXES = %w[/dashboard /products /bundles /customers /payouts /settings /discover].freeze

  # Matched longest-prefix first so /dashboard/sales resolves to analytics rather than to a shorter
  # sibling.
  ORDERED_PROMOTABLE_PREFIXES = PATH_PREFIXES.sort_by { |prefix, _| -prefix.length }.freeze

  # Returns the promotable item key a dashboard path belongs to, or nil.
  def item_for_path(path)
    normalized = normalize_path(path)
    return if normalized.blank?

    ORDERED_PROMOTABLE_PREFIXES.find { |prefix, _| path_matches?(normalized, prefix) }&.last
  end

  # Whether the path is a dashboard surface at all. Everything else (storefronts, checkout, the
  # public site) must not touch a user's promotions, since those pages do not render this nav.
  def dashboard_path?(path)
    normalized = normalize_path(path)
    return false if normalized.blank?

    (CORE_PATH_PREFIXES + PATH_PREFIXES.keys).any? { |prefix| path_matches?(normalized, prefix) }
  end

  # The promotions a user has already earned before this feature existed: whatever their store
  # already contains counts as having used the destination. Seeded once per user, then the nav grows
  # only through actual visits.
  def earned_items(user:, seller:)
    return [] if seller.nil?

    items = []
    items << "profile" if seller.products.alive.exists?
    items << "pages" if seller.pages.exists?
    items << "collaborators" if seller.collaborators.exists?
    items << "checkout" if seller.offer_codes.exists? || seller.upsells.exists?
    items << "emails" if seller.installments.exists?
    items << "workflows" if seller.workflows.exists?
    items << "analytics" if seller.sales.exists?
    items << "affiliates" if seller.direct_affiliates.alive.exists?
    items << "community" if seller.seller_communities.alive.exists?
    items << "agent" if seller.ai_conversations.exists?
    items << "library" if user.purchases.exists?
    items
  end

  private
    def normalize_path(path)
      path.to_s.chomp("/").downcase
    end

    def path_matches?(normalized, prefix)
      normalized == prefix || normalized.start_with?("#{prefix}/")
    end
end
