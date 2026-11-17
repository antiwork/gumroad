# frozen_string_literal: true

# Bounds the composite-aggregation walks in CreatorAnalytics::ProductPageViews and
# CreatorAnalytics::Sales. One referral request runs both walks, so the deadline is
# request-scoped rather than per walk: two per-walk limits would add up past the
# Rack::Timeout budget they exist to stay under.
module CreatorAnalytics::Pagination
  # Half of rack_timeout.rb's service_timeout, leaving room for the rest of the action and for
  # the page still in flight when the deadline passes.
  BUDGET_SECONDS = 60
  # Backstop for a walk whose pages are each fast enough never to reach the deadline.
  MAX_PAGES = 20

  # Raised instead of returning the pages collected so far: a short page is indistinguishable
  # from a complete one, so a truncated walk would silently misreport the seller's analytics.
  class BudgetExceeded < StandardError; end

  def self.within_budget
    Current.analytics_pagination_deadline = monotonic_now + BUDGET_SECONDS
    yield
  ensure
    Current.analytics_pagination_deadline = nil
  end

  def self.exhausted?(pages:)
    return true if pages >= MAX_PAGES

    deadline = Current.analytics_pagination_deadline
    deadline.present? && monotonic_now >= deadline
  end

  def self.monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
