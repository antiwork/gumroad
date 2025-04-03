# frozen_string_literal: true

class UtmLinkSaleAttributionJob
  include Sidekiq::Job

  ATTRIBUTION_WINDOW = 7.days

  sidekiq_options queue: :low, lock: :until_executed, retry: 3

  def perform(order_id, browser_guid)
    purchases_by_seller = Order.find(order_id).purchases.successful.group_by(&:seller_id)

    # Fetch only the latest visit per UtmLink
    latest_visits_query = <<~SQL.squish
      SELECT utm_link_id, MAX(created_at) AS latest_visit_at
      FROM utm_link_visits
      WHERE browser_guid = '#{ActiveRecord::Base.connection.quote_string(browser_guid)}'
      AND created_at >= '#{ATTRIBUTION_WINDOW.ago.beginning_of_day.strftime("%Y-%m-%d %H:%M:%S")}'
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
              .order(created_at: :desc)

    purchase_attribution_map = {}

    visits.find_each do |visit|
      utm_link = visit.utm_link
      next unless Feature.active?(:utm_links, utm_link.seller)

      qualified_purchases = purchases_by_seller[utm_link.seller_id]
      next if qualified_purchases.blank?

      if utm_link.target_product_page?
        qualified_purchases.select! { _1.link_id == utm_link.target_resource_id }
      end

      # Attribute only one visit (the most recent among all applicable links) per purchase
      qualified_purchases.each { purchase_attribution_map[_1.id] ||= { visit:, purchase: _1 } }
    end

    purchase_attribution_map.each do |purchase_id, info|
      purchase = info.fetch(:purchase)
      visit = info.fetch(:visit)
      utm_link = visit.utm_link
      visit.update!(country_code: Compliance::Countries.find_by_name(purchase.country)&.alpha2) if visit.country_code.blank? && purchase.country.present?

      utm_link.utm_link_driven_sales.create!(utm_link_visit: visit, purchase:)
    end
  end
end
