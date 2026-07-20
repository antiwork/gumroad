# frozen_string_literal: true

module UtmLinkTracking
  extend ActiveSupport::Concern

  private
    def track_utm_link_visit
      # Used by the RecordNotUnique rescue below, which re-runs this method once via
      # `retry`. `||=` (not plain assignment) so the flag survives the retry re-running
      # the method body — a plain assignment would reset it and loop forever.
      retried_after_duplicate_insert ||= false

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
      return unless Feature.active?(:utm_links, seller)

      target_resource_type, target_resource_id = determine_utm_link_target_resource(seller)
      return if target_resource_type.blank?

      utm_params = required_params.merge(optional_params).transform_values { _1.to_s.strip.downcase.gsub(/[^a-z0-9\-_]/u, "-").first(UtmLink::MAX_UTM_PARAM_LENGTH).presence }

      ActiveRecord::Base.transaction do
        # Look up existing links with the "alive" scope (not "active") so we see links the
        # seller has disabled. The model's uniqueness validation also checks against "alive"
        # links, so if we only searched "active" links here we could miss a disabled duplicate,
        # try to create a new link, and have the save fail — which used to surface as a 422
        # error on the buyer-facing page.
        utm_link = UtmLink.alive.find_or_initialize_by(utm_params.merge(target_resource_type:, target_resource_id:))

        # A disabled link means the seller intentionally paused tracking for these UTM
        # parameters — respect that and don't record the visit.
        return if utm_link.persisted? && !utm_link.enabled?

        auto_create_utm_link(utm_link, seller) if utm_link.new_record?
        return unless utm_link.persisted?
        return unless Feature.active?(:utm_links, utm_link.seller)

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
    rescue ActiveRecord::RecordNotUnique => e
      # Two simultaneous first visits with the same UTM parameters can both find no existing
      # link and both try to auto-create it; the request that loses the race hits the
      # database's unique index. Since the winning request has committed the link by the time
      # we get here, retrying once lets this request find that link and still record the
      # visit. If it fails a second time something else is wrong — report and swallow so the
      # buyer-facing page still renders (analytics must never break the page).
      if retried_after_duplicate_insert
        ErrorNotifier.notify(e, utm_params: params.permit(:utm_source, :utm_medium, :utm_campaign, :utm_term, :utm_content).to_h)
      else
        retried_after_duplicate_insert = true
        retry
      end
    rescue ActiveRecord::RecordInvalid => e
      # Analytics tracking must never break the buyer-facing page. A validation failure
      # should be reported and swallowed, not raised.
      ErrorNotifier.notify(e, utm_params: params.permit(:utm_source, :utm_medium, :utm_campaign, :utm_term, :utm_content).to_h)
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
