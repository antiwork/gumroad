# frozen_string_literal: true

class UtmLinkSaleAttributionJob
  include Sidekiq::Job

  ATTRIBUTION_WINDOW = 7.days

  sidekiq_options queue: :low, lock: :until_executed, retry: 3

  def perform(order_id, browser_guid)
    purchases = Order.find(order_id).purchases.successful.to_a
    return if purchases.empty?
    purchases_by_seller = purchases.group_by(&:seller_id)
    # Exclusive upper bound, so a revisit after the sale can't displace the pre-sale visit
    # to the same link in the MAX below. purchases.created_at is second-precision.
    visits_before = purchases.map(&:created_at).max + 1.second

    # Fetch only the latest visit per UtmLink
    latest_visits_query = <<~SQL.squish
      SELECT utm_link_id, MAX(created_at) AS latest_visit_at
      FROM utm_link_visits
      WHERE browser_guid = '#{ActiveRecord::Base.connection.quote_string(browser_guid)}'
      AND created_at >= '#{ATTRIBUTION_WINDOW.ago.beginning_of_day.strftime("%Y-%m-%d %H:%M:%S")}'
      AND created_at < '#{visits_before.utc.strftime("%Y-%m-%d %H:%M:%S")}'
      GROUP BY utm_link_id
    SQL

    visits = UtmLinkVisit
              .includes(:utm_link)
              .joins(<<~SQL.squish)
                INNER JOIN (#{latest_visits_query}) AS latest_visits
                ON utm_link_visits.utm_link_id = latest_visits.utm_link_id
                AND utm_link_visits.created_at = latest_visits.latest_visit_at
              SQL
              .where(browser_guid:)
              .where("utm_link_visits.created_at >= ?", ATTRIBUTION_WINDOW.ago.beginning_of_day)
              .where("utm_link_visits.created_at < ?", visits_before)
              .order(created_at: :desc, id: :desc)

    purchase_attribution_map = {}

    # #each, not find_each: find_each forces primary-key order and discards the ordering above.
    visits.each do |visit|
      utm_link = visit.utm_link
      qualified_purchases = purchases_by_seller[utm_link.seller_id]
      next if qualified_purchases.blank?

      # A copy: the seller's list is shared by every visit, so narrowing it in place would
      # strip attribution from the purchases the next visit should have claimed.
      if utm_link.target_product_page?
        qualified_purchases = qualified_purchases.select { _1.link_id == utm_link.target_resource_id }
      end

      # purchases.created_at is second-precision, so a visit in the same second still counts.
      qualified_purchases.each do |purchase|
        next if visit.created_at.change(usec: 0) > purchase.created_at
        purchase_attribution_map[purchase.id] ||= { visit:, purchase: }
      end
    end

    purchase_attribution_map.each do |purchase_id, info|
      purchase = info.fetch(:purchase)
      visit = info.fetch(:visit)
      utm_link = visit.utm_link
      visit.update!(country_code: Compliance::Countries.find_by_name(purchase.country)&.alpha2) if visit.country_code.blank? && purchase.country.present?

      utm_link.utm_link_driven_sales.where(utm_link_visit: visit, purchase:).first_or_create!
    end
  end
end
