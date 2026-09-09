# frozen_string_literal: true

# Funnel events for optional social connect. Nothing here moves money or
# releases a hold — it only writes Event rows for later measurement.
class SocialConnectFunnel
  STAGES = %w[offered attempted connected failed reviewed hold_released].freeze
  PROVIDERS = (SocialConnectVerification::PLATFORMS + %w[none]).freeze
  SURFACES = %w[
    getting_started
    account_review
    profile
    omniauth
    admin_social_connections
    mark_compliant
    payouts_resume
  ].freeze
  CONNECTION_NAME_TO_PROVIDER = {
    "X" => "twitter",
    "YouTube" => "youtube",
    "Instagram" => "instagram",
    "TikTok" => "tiktok",
  }.freeze
  OMNIAUTH_CONNECT_PROVIDERS = %w[twitter youtube instagram tiktok].freeze
  TWITTER_LINK_STATES = %w[link_twitter_account async_link_twitter_account].freeze

  class << self
    def event_name(stage)
      "social_connect_#{stage}"
    end

    def record!(user:, stage:, provider:, surface:, extra: nil, once: false)
      return if user.blank?
      return unless STAGES.include?(stage)
      return unless PROVIDERS.include?(provider.to_s)
      return unless SURFACES.include?(surface.to_s)

      name = event_name(stage)
      if once && Event.exists?(user_id: user.id, event_name: name, parent_referrer: provider, view_url: surface)
        return
      end

      Event.create!(
        event_name: name,
        user_id: user.id,
        parent_referrer: provider,
        view_url: surface,
        referrer: extra.to_s.presence&.truncate(190),
      )
    rescue StandardError => e
      Rails.logger.error("SocialConnectFunnel #{stage}/#{provider} failed for user #{user&.id}: #{e.class}: #{e.message}")
      nil
    end

    def record_offers!(user:, connections:, surface:, skip: false)
      return if skip || user.blank? || connections.blank?

      Array(connections).each do |connection|
        attrs = connection.respond_to?(:symbolize_keys) ? connection.symbolize_keys : connection
        next if truthy?(attrs[:connected])

        provider = attrs[:provider].presence || CONNECTION_NAME_TO_PROVIDER[attrs[:name].to_s]
        next if provider.blank?

        record!(user:, stage: "offered", provider:, surface:, once: true)
      end
    end

    def record_attempted_from_omniauth!(env)
      provider = env["omniauth.strategy"]&.name.to_s
      return unless OMNIAUTH_CONNECT_PROVIDERS.include?(provider)
      return if provider == "twitter" && !twitter_link_request?(env)

      user = env["warden"]&.user
      return if user.blank?

      record!(user:, stage: "attempted", provider:, surface: "omniauth")
    end

    def record_reviewed!(user:, verifications:)
      return if user.blank?

      # Pre-offer admin GETs must not permanently consume "reviewed"; only
      # record after an offer, and allow another row after a later offer.
      last_offer_at = Event.where(user_id: user.id, event_name: event_name("offered")).maximum(:created_at)
      return if last_offer_at.blank?

      linked = Array(verifications).filter_map { |verification| verification.platform if verification.currently_linked? }.uniq
      providers = linked.empty? ? %w[none] : linked
      providers.each do |provider|
        already = Event.where(
          user_id: user.id,
          event_name: event_name("reviewed"),
          parent_referrer: provider,
          view_url: "admin_social_connections",
        ).where("created_at >= ?", last_offer_at).exists?
        next if already

        record!(user:, stage: "reviewed", provider:, surface: "admin_social_connections")
      end
    rescue StandardError => e
      Rails.logger.error("SocialConnectFunnel reviewed failed for user #{user&.id}: #{e.class}: #{e.message}")
      nil
    end

    def record_hold_released!(user, surface:)
      return if user.blank?

      # Lifetime once breaks post-offer timing when a pre-offer compliant
      # transition already consumed the row; re-allow after a later offer.
      last_offer_at = Event.where(user_id: user.id, event_name: event_name("offered")).maximum(:created_at)
      linked = user.social_connect_verifications.current.filter_map { |verification| verification.platform if verification.currently_linked? }.uniq
      providers = linked.empty? ? %w[none] : linked
      providers.each do |provider|
        scope = Event.where(
          user_id: user.id,
          event_name: event_name("hold_released"),
          parent_referrer: provider,
          view_url: surface,
        )
        if last_offer_at.present?
          next if scope.where("created_at >= ?", last_offer_at).exists?
        elsif scope.exists?
          next
        end

        record!(user:, stage: "hold_released", provider:, surface:)
      end
    rescue StandardError => e
      Rails.logger.error("SocialConnectFunnel hold_released failed for user #{user&.id}: #{e.class}: #{e.message}")
      nil
    end

    private
      def twitter_link_request?(env)
        params = env["omniauth.params"] || {}
        state = params["state"].presence || params[:state].presence
        state = Rack::Utils.parse_query(env["QUERY_STRING"].to_s)["state"] if state.blank?
        TWITTER_LINK_STATES.include?(state.to_s)
      end

      def truthy?(value)
        ActiveModel::Type::Boolean.new.cast(value)
      end
  end
end
