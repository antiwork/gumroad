# frozen_string_literal: true

module UtmLinkTracking
  extend ActiveSupport::Concern

  private
    def track_utm_link_visit
      # Used by the duplicate-link rescue below, which re-runs this method once via
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

      target_resource_type, target_resource_id = determine_utm_link_target_resource(seller)
      return if target_resource_type.blank?

      utm_params = required_params.merge(optional_params).transform_values { _1.to_s.strip.downcase.gsub(/[^a-z0-9\-_]/u, "-").first(UtmLink::MAX_UTM_PARAM_LENGTH).presence }

      ActiveRecord::Base.transaction do
        # Look up existing links with the "alive" scope (not "active") so we see links the
        # seller has disabled. The model's uniqueness validation also checks against "alive"
        # links, so if we only searched "active" links here we could miss a disabled duplicate,
        # try to create a new link, and have the save fail — which used to surface as a 422
        # error on the buyer-facing page.
        #
        # Order by id so the lookup is deterministic when duplicate alive links exist.
        # Duplicates happen when two simultaneous first visits both insert the same link:
        # MySQL's unique index can't stop that when a nullable column (utm_term, utm_content,
        # target_resource_id) is NULL, because NULLs never conflict in unique indexes. Without
        # an explicit order, alternating visits could split between the duplicate rows;
        # always picking the oldest row keeps all stats accumulating on one link.
        utm_link = UtmLink.alive
          .where(utm_params.merge(target_resource_type:, target_resource_id:))
          .order(:id)
          .first_or_initialize

        # A disabled link means the seller intentionally paused tracking for these UTM
        # parameters — respect that and don't record the visit.
        return if utm_link.persisted? && !utm_link.enabled?

        auto_create_utm_link(utm_link, seller) if utm_link.new_record?
        return unless utm_link.persisted?

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
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      # Two simultaneous first visits with the same UTM parameters can both find no existing
      # link and both try to auto-create it. The request that loses the race fails in one of
      # two ways, depending on when the winner commits relative to the loser's save:
      #
      #   - ActiveRecord::RecordNotUnique — the winner commits after the loser's uniqueness
      #     validation query ran, so the loser passes validation and then hits the database's
      #     unique index on insert.
      #   - ActiveRecord::RecordInvalid — the winner commits before the loser's uniqueness
      #     validation query runs, so the loser's UtmLink#utm_fields_are_unique_per_target_resource
      #     validation sees the winner's row and fails with "A link with similar UTM parameters
      #     already exists".
      #
      # There is a third outcome: MySQL unique indexes treat NULL values as non-conflicting,
      # and this index includes nullable columns (utm_term, utm_content, target_resource_id),
      # so two racers can BOTH insert successfully and leave duplicate alive rows. Visits keep
      # working for such links — the lookup above deterministically picks the oldest duplicate,
      # and the model only re-validates uniqueness when identifying fields change (not on
      # click-timestamp updates). Merging the duplicate rows themselves is handled by the
      # Onetime::DedupUtmLinks task; see https://github.com/antiwork/gumroad/issues/5989.
      #
      # In both recoverable cases the winning request has committed the link by the time we get here, so
      # retrying once lets this request find that link and still record the visit. For
      # RecordInvalid we only retry when the failing record is the auto-created UtmLink itself
      # (a new record) — validation failures on other records in this block aren't races and
      # retrying wouldn't help. If any failure repeats after the retry, something else is
      # wrong — report and swallow so the buyer-facing page still renders (analytics must
      # never break the page).
      race_recoverable = e.is_a?(ActiveRecord::RecordNotUnique) ||
        (e.record.is_a?(UtmLink) && e.record.new_record?)

      if race_recoverable && !retried_after_duplicate_insert
        retried_after_duplicate_insert = true
        retry
      end

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
