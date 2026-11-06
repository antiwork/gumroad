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

      UtmLinkVisitRecorder.new(
        seller:, target_resource_type:, target_resource_id:, utm_params:, user: current_user, referrer: request.referrer,
        ip_address: request.remote_ip, user_agent: request.user_agent, browser_guid: cookies[:_gumroad_guid]
      ).record
    rescue ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked => e
      # Timestamp updates can contend with another visit or the dedupe job. Do not retry:
      # lock timeouts already consumed the wait budget, and analytics must not block the page.
      ErrorNotifier.notify(e, utm_params: params.permit(:utm_source, :utm_medium, :utm_campaign, :utm_term, :utm_content).to_h)
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      # Non-race uniqueness/validation failures cannot converge or retry safely. Report and
      # swallow so analytics never breaks the buyer-facing page.
      ErrorNotifier.notify(e, utm_params: params.permit(:utm_source, :utm_medium, :utm_campaign, :utm_term, :utm_content).to_h)
    rescue ActiveRecord::StatementInvalid => e
      # A read-only primary rejects the write before running it while the page's own reads
      # still succeed, so report the lost visit instead of failing the request.
      raise unless MysqlReadOnlyPrimaryRetry.read_only_error?(e)
      ErrorNotifier.notify(e, utm_params: params.permit(:utm_source, :utm_medium, :utm_campaign, :utm_term, :utm_content).to_h)
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
