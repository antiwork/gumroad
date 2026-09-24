# frozen_string_literal: true

class UtmLinkSaleAttributionJob
  include Sidekiq::Job

  ATTRIBUTION_WINDOW = 7.days

  sidekiq_options queue: :low, lock: :until_executed, retry: 3

  def perform(order_id, browser_guid)
    purchase_attribution_map = {}

    # Purchases in one order can land in different seconds, so each purchase time gets its own
    # visit cutoff: a revisit between two purchases must not displace the earlier one's visit.
    Order.find(order_id).purchases.successful.group_by(&:created_at).each do |purchased_at, purchases|
      purchases_by_seller = purchases.group_by(&:seller_id)

      # #each, not find_each: find_each forces primary-key order and discards the ordering.
      latest_visits_until(browser_guid, purchased_at).each do |visit|
        utm_link = visit.utm_link
        qualified_purchases = purchases_by_seller[utm_link.seller_id]
        next if qualified_purchases.blank?

        # A copy: the seller's list is shared by every visit, so narrowing it in place would
        # strip attribution from the purchases the next visit should have claimed.
        if utm_link.target_product_page?
          qualified_purchases = qualified_purchases.select { _1.link_id == utm_link.target_resource_id }
        end

        qualified_purchases.each do |purchase|
          purchase_attribution_map[purchase.id] ||= { visit:, purchase: }
        end
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

  private
    # Latest visit per UtmLink, newest first. purchases.created_at is second-precision, so the
    # exclusive bound is the next second and a visit in the purchase's own second still counts.
    def latest_visits_until(browser_guid, purchased_at)
      visits_before = purchased_at + 1.second

      latest_visits_query = <<~SQL.squish
        SELECT utm_link_id, MAX(created_at) AS latest_visit_at
        FROM utm_link_visits
        WHERE browser_guid = '#{ActiveRecord::Base.connection.quote_string(browser_guid)}'
        AND created_at >= '#{ATTRIBUTION_WINDOW.ago.beginning_of_day.strftime("%Y-%m-%d %H:%M:%S")}'
        AND created_at < '#{visits_before.utc.strftime("%Y-%m-%d %H:%M:%S")}'
        GROUP BY utm_link_id
      SQL

      UtmLinkVisit
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
    end
end
