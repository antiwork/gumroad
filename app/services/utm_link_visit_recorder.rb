# frozen_string_literal: true

# A visit to a UTM-tagged page: the seller's link for these parameters, created when new, and the
# visit on it. UtmLinkTracking records it in the request; RecordUtmLinkVisitJob records one go_web
# served, at the time it was made.
class UtmLinkVisitRecorder
  def initialize(seller:, target_resource_type:, target_resource_id:, utm_params:, user:, referrer:, ip_address:, user_agent:, browser_guid:, visited_at: nil)
    @seller = seller
    @target_resource_type = target_resource_type
    @target_resource_id = target_resource_id
    @utm_params = utm_params
    @user = user
    @referrer = referrer
    @ip_address = ip_address
    @user_agent = user_agent
    @browser_guid = browser_guid
    @visited_at = visited_at
  end

  def record
    # Match the model's alive-scope uniqueness check, including disabled links; otherwise
    # this can miss a duplicate and turn a buyer-facing GET into a validation error.
    # Deterministically pick the oldest alive duplicate because nullable unique-index
    # columns can allow duplicate rows, and splitting visits would fragment stats.
    utm_link = UtmLink.alive
      .where(utm_params.merge(target_resource_type:, target_resource_id:))
      .order(:id)
      .first_or_initialize

    # A disabled link means the seller intentionally paused tracking for these UTM
    # parameters — respect that and don't record the visit.
    return if utm_link.persisted? && !utm_link.enabled?

    if utm_link.new_record?
      begin
        auto_create_utm_link(utm_link)
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
        # The auto-create insert is outside the visit transaction, so a race winner
        # should now be committed and visible to an uncached lookup. Converge onto it;
        # if no winner exists, this was not the race path and the caller reports it.
        utm_link = UtmLink.uncached do
          UtmLink.alive
            .where(utm_params.merge(seller_id: seller.id, target_resource_type:, target_resource_id:))
            .order(:id)
            .first
        end
        raise if utm_link.blank?
      end
    end
    return unless utm_link.persisted?
    # The converged winner could have been disabled by the seller while we handled the
    # race — respect that the same way the lookup above does, and don't record the visit.
    return if !utm_link.enabled?

    track_visit(utm_link)
  end

  private
    attr_reader :seller, :target_resource_type, :target_resource_id, :utm_params, :user, :referrer, :ip_address,
                :user_agent, :browser_guid, :visited_at

    def track_visit(utm_link)
      clicked_at = visited_at || Time.current
      ActiveRecord::Base.transaction do
        visit = { user:, referrer:, ip_address:, user_agent:, browser_guid:, country_code: GeoIp.lookup(ip_address)&.country_code }
        visit.merge!(created_at: visited_at, updated_at: visited_at) if visited_at
        utm_link.utm_link_visits.create!(visit)

        # A visit recorded after a later one keeps the link's click range in order.
        utm_link.first_click_at = [utm_link.first_click_at, clicked_at].compact.min
        utm_link.last_click_at = [utm_link.last_click_at, clicked_at].compact.max
        utm_link.save!
      end

      # Keep the visit if enqueue fails; the next stats job recounts all persisted visits.
      begin
        UpdateUtmLinkStatsJob.perform_async(utm_link.id)
      rescue *REDIS_TRANSPORT_ERRORS => e
        begin
          ErrorNotifier.notify(e, source: "utm_stats_enqueue", utm_link_id: utm_link.id)
        rescue StandardError => reporting_error
          Rails.logger.warn("UTM stats enqueue reporting failed: #{reporting_error.class}")
        end
      end
    end

    def auto_create_utm_link(utm_link)
      utm_link.seller = seller
      utm_link.title = utm_link.default_title
      utm_link.ip_address = ip_address
      utm_link.browser_guid = browser_guid
      utm_link.save!
    end
end
