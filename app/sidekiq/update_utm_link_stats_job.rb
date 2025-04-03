# frozen_string_literal: true

class UpdateUtmLinkStatsJob
  include Sidekiq::Job

  sidekiq_options queue: :low, lock: :until_executed, retry: 1

  def perform(utm_link_id)
    utm_link = UtmLink.find(utm_link_id)

    utm_link.update!(
      total_clicks: utm_link.utm_link_visits.count,
      unique_clicks: utm_link.utm_link_visits.distinct.count(:browser_guid)
    )
  end
end
