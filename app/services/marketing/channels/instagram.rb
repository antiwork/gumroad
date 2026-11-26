# frozen_string_literal: true

class Marketing::Channels::Instagram
  Result = Struct.new(:action, :intent_url, :connect_path, keyword_init: true)

  # Each Instagram call times out at 15s and a post is at most a handful of them, so a
  # claim older than this belongs to a request that died.
  ATTEMPT_TIMEOUT = 2.minutes
  # Meta downloads and checks the image before the container can be published. For one
  # image that takes a second or two; a seller's request should not wait much longer.
  CONTAINER_POLLS = 5
  CONTAINER_POLL_INTERVAL = 2.seconds

  def initialize(action, confirmation_token: nil)
    @action = action
    @confirmation_token = confirmation_token
  end

  def call
    return result if action.posted?

    # As on X: a claimed attempt is resolved by claim!, before any check that could
    # reopen it and let a post Instagram may already have published be sent again.
    if action.queued?
      claim!
      return result
    end

    if !action.approved?
      action.update!(error_code: "not_approved")
    elsif action.link.user_id != action.user_id
      fail_with!("product_ownership_changed")
    elsif !action.link.published?
      fail_with!("product_not_published")
    elsif !image.available?
      # Stays open: adding a cover image is all it takes, and the same action can then post.
      action.update!(error_code: Marketing::Action::INSTAGRAM_IMAGE_MISSING)
    elsif !identity&.can_publish?
      require_reconnect!
    elsif claim!
      post!
    end

    result
  end

  private
    attr_reader :action

    def identity = @identity ||= action.user.instagram_identity
    def image = @image ||= Marketing::InstagramImage.new(action.link)
    def api = @api ||= Marketing::InstagramApi.new(identity)

    # Same claim as Marketing::Channels::X: the approved→queued transition under the row
    # lock decides which of two concurrent executes may call out.
    def claim!
      action.with_lock do
        action.reload
        next false unless action.approved? || action.queued?

        if action.queued?
          next false if in_flight?

          fail_with!("instagram_post_result_unknown")
          next false
        end

        action.verify_confirmation!(@confirmation_token) if @confirmation_token
        action.queue!
        true
      end
    end

    def in_flight? = action.queued_at.present? && action.queued_at > ATTEMPT_TIMEOUT.ago

    def post!
      refresh_token_if_due

      container = api.create_image_container(image_url: image.url, caption: action.post_text)
      # Nothing is public until the container is published, so every failure up to that
      # call is a clean one: the seller can simply try again.
      return settle_unpublished(container, "instagram_rejected") unless container.ok?
      return fail_with!("instagram_image_not_ready") unless container_ready?(container.id)

      published = api.publish(container.id)
      if published.ok?
        action.external_post_id = published.id
        action.external_url = api.permalink(published.id).permalink || "https://www.instagram.com/#{identity.handle}/"
        action.error_code = nil
        action.mark_posted!
      elsif published.unauthorized?
        require_reconnect!
      elsif published.rejected?
        fail_with!("instagram_rejected")
      else
        # A 5xx or a dropped connection on the publish call itself: Instagram may have
        # published it, so it is never resent.
        fail_with!("instagram_post_result_unknown")
      end
    end

    def settle_unpublished(response, rejection_code)
      return require_reconnect! if response.unauthorized?

      fail_with!(response.rejected? ? rejection_code : "instagram_unavailable")
    end

    def container_ready?(container_id)
      CONTAINER_POLLS.times do |attempt|
        sleep(CONTAINER_POLL_INTERVAL) if attempt > 0
        status = api.container_status(container_id).status_code
        return true if status == "FINISHED"
        return false if %w[ERROR EXPIRED].include?(status)
      end
      false
    end

    # Renewing here, when the seller is posting anyway, needs no scheduled job. A failed
    # renewal is not a failed post: the current token is still valid.
    def refresh_token_if_due
      return unless identity.token_due_for_refresh?

      refreshed = Marketing::InstagramApi.refresh_token(identity.access_token)
      return unless refreshed.ok? && refreshed.access_token.present?

      identity.update!(access_token: refreshed.access_token, access_token_expires_at: refreshed.expires_in.seconds.from_now)
    end

    # The connection cannot publish (never granted, expired, or revoked) and reconnecting
    # fixes it, so the action stays open with the reason, as it does on X.
    def require_reconnect!
      action.error_code = Marketing::Action::INSTAGRAM_PUBLISH_PERMISSION_MISSING
      action.require_reconnect!
    end

    def fail_with!(code)
      action.error_code = code
      action.mark_failed!
    end

    def result
      Result.new(
        action:,
        # Instagram has no share link that opens a prefilled post.
        intent_url: nil,
        connect_path: Rails.application.routes.url_helpers.settings_social_connections_path(
          social_connect_origin: "marketing", social_connect_product: action.link.unique_permalink),
      )
    end
end
