# frozen_string_literal: true

class Marketing::Channels::X
  Result = Struct.new(:action, :intent_url, :connect_path, keyword_init: true)

  # A claim older than this is an attempt whose request died mid-flight (the X call
  # itself times out at 15s), so a later execute has to resolve it, not resend it.
  ATTEMPT_TIMEOUT = 2.minutes

  def initialize(action)
    @action = action
  end

  def call
    return result if action.posted?

    # A claimed attempt is resolved by claim! (wait while it is in flight, else close it
    # as an unknown result). Running the preflight checks first would reopen it to
    # :approved — require_reconnect! transitions out of :queued — and let a post that X
    # may already have accepted be sent again.
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
    elsif action.user.twitter_oauth_token.blank? || action.user.twitter_oauth_secret.blank?
      require_reconnect!
    elsif claim!
      post!
    end

    result
  end

  private
    attr_reader :action

    # Two executes of one action load separate instances, and X has no idempotency
    # key, so the approved→queued transition under the row lock is the claim: only
    # the request that wins it may call out.
    def claim!
      action.with_lock do
        action.reload
        next false unless action.approved? || action.queued?

        if action.queued?
          next false if in_flight?

          # X may have accepted the post before the attempt was abandoned, so a
          # resend would duplicate it. Close it and let the card say so.
          fail_with!("x_post_result_unknown")
          next false
        end

        action.queue!
        true
      end
    end

    def in_flight? = action.queued_at.present? && action.queued_at > ATTEMPT_TIMEOUT.ago

    def post!
      response = Marketing::XApi.post_tweet(user: action.user, text: action.post_text)

      if response.created?
        action.external_post_id = response.tweet_id
        action.external_url = "https://x.com/#{action.user.twitter_handle}/status/#{response.tweet_id}"
        action.error_code = nil
        action.mark_posted!
      elsif response.write_forbidden?
        require_reconnect!
      elsif response.rejected?
        # X refused the request outright (duplicate copy, over-length text, app not
        # enrolled). Nothing was posted and reconnecting would not change that.
        fail_with!("x_rejected")
      else
        # Anything else — a 5xx, or a nil status from a connection that died — leaves the
        # post's fate unknown, and that is the case where X most likely did receive it.
        fail_with!("x_post_result_unknown")
      end
    end

    # Nothing reached X and the seller can fix this by reconnecting, so the action
    # stays open with the reason recorded: failing it would hide the reconnect
    # fallback until the next reload and mint a fresh recommendation every time.
    def require_reconnect!
      action.error_code = "x_write_permission_missing"
      action.require_reconnect!
    end

    def fail_with!(code)
      action.error_code = code
      action.mark_failed!
    end

    def result
      Result.new(
        action:,
        intent_url: "https://twitter.com/intent/tweet?#{{ text: action.copy, url: action.utm_link&.short_url }.compact.to_query}",
        connect_path: Rails.application.routes.url_helpers.settings_social_connections_path,
      )
    end
end
