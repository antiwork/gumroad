# frozen_string_literal: true

module UtmLinkTracking
  extend ActiveSupport::Concern

  private
    def track_utm_link_visit
      return unless request.get?

      required_params = {
        utm_source: params[:utm_source].presence,
        utm_medium: params[:utm_medium].presence,
        utm_campaign: params[:utm_campaign].presence
      }

      optional_params = {
        utm_term: params[:utm_term].presence,
        utm_content: params[:utm_content].presence
      }

      return if required_params.values.any?(&:blank?)
      return if cookies[:_gumroad_guid].blank? # i.e. cookies are disabled

      return unless UserCustomDomainConstraint.matches?(request)
      seller = CustomDomain.find_by_host(request.host)&.user || Subdomain.find_seller_by_request(request)
      return if seller.blank?

      target_resource_type, target_resource_id = determine_utm_link_target_resource(seller)
      return if target_resource_type.blank?

      utm_params = required_params.merge(optional_params).transform_values { _1.to_s.strip.downcase.gsub(/[^a-z0-9\-_]/u, "-").first(UtmLink::MAX_UTM_PARAM_LENGTH).presence }

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
          auto_create_utm_link(utm_link, seller)
        rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
          # The auto-create insert is outside the visit transaction, so a race winner
          # should now be committed and visible to an uncached lookup. Converge onto it;
          # if no winner exists, this was not the race path and the outer rescue reports it.
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
    rescue ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked => e
      # Timestamp updates can contend with another visit or the dedupe job. Do not retry:
      # lock timeouts already consumed the wait budget, and analytics must not block the page.
      ErrorNotifier.notify(e, utm_params: params.permit(:utm_source, :utm_medium, :utm_campaign, :utm_term, :utm_content).to_h)
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      # Non-race uniqueness/validation failures cannot converge or retry safely. Report and
      # swallow so analytics never breaks the buyer-facing page.
      ErrorNotifier.notify(e, utm_params: params.permit(:utm_source, :utm_medium, :utm_campaign, :utm_term, :utm_content).to_h)
    end

    def track_visit(utm_link)
      ActiveRecord::Base.transaction do
        utm_link.utm_link_visits.create!(
          user: current_user,
          referrer: request.referrer,
          ip_address: request.remote_ip,
          user_agent: request.user_agent,
          browser_guid: cookies[:_gumroad_guid],
          country_code: GeoIp.lookup(request.remote_ip)&.country_code
        )

        utm_link.first_click_at ||= Time.current
        utm_link.last_click_at = Time.current
        utm_link.save!

        UpdateUtmLinkStatsJob.perform_async(utm_link.id)
      end
    end

    def auto_create_utm_link(utm_link, seller)
      utm_link.seller = seller
      utm_link.title = utm_link.default_title
      utm_link.ip_address = request.remote_ip
      utm_link.browser_guid = cookies[:_gumroad_guid]
      utm_link.save!
    end

    def determine_utm_link_target_resource(seller)
      if request.path == root_path
        [UtmLink.target_resource_types[:profile_page], nil]
      elsif params[:id].present? && request.path.starts_with?(short_link_path(params[:id]))
        product = if seller&.custom_domain&.product&.general_permalink == params[:id]
          seller.custom_domain&.product
        else
          Link.fetch_leniently(params[:id], user: seller)
        end
        return if product.blank?
        [UtmLink.target_resource_types[:product_page], product.id]
      elsif params[:slug].present? && request.path.ends_with?(custom_domain_view_post_path(params[:slug]))
        post = seller.installments.find_by_slug(params[:slug])
        return if post.blank?
        [UtmLink.target_resource_types[:post_page], post.id]
      elsif request.path == custom_domain_subscribe_path
        [UtmLink.target_resource_types[:subscribe_page], nil]
      end
    end
end
