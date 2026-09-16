# frozen_string_literal: true

class Marketing::Channels::X
  Result = Struct.new(:action, :intent_url, :connect_path, keyword_init: true)

  def initialize(action)
    @action = action
  end

  def call
    return result if action.posted?

    if !action.approved? && !action.queued?
      action.update!(error_code: "not_approved")
    elsif action.link.user_id != action.user_id
      fail_with!("product_ownership_changed")
    elsif !action.link.published?
      fail_with!("product_not_published")
    elsif action.user.twitter_oauth_token.blank? || action.user.twitter_oauth_secret.blank?
      fail_with!("x_write_permission_missing")
    else
      post!
    end

    result
  end

  private
    attr_reader :action

    def post!
      action.queue! if action.approved?
      response = Marketing::XApi.post_tweet(user: action.user, text: action.post_text)

      if response.created?
        action.external_post_id = response.tweet_id
        action.external_url = "https://x.com/#{action.user.twitter_handle}/status/#{response.tweet_id}"
        action.mark_posted!
      elsif response.write_forbidden?
        fail_with!("x_write_permission_missing")
      else
        fail_with!("x_api_error")
      end
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
