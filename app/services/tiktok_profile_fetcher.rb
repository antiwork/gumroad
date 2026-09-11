# frozen_string_literal: true

class TiktokProfileFetcher
  USER_INFO_URL = "https://open.tiktokapis.com/v2/user/info/"
  FIELDS = "open_id,union_id,avatar_url,display_name,username,profile_web_link,follower_count,video_count"

  def initialize(access_token)
    @access_token = access_token
  end

  def fetch
    return if @access_token.blank?

    response = HTTParty.get(
      USER_INFO_URL,
      query: { fields: FIELDS },
      headers: { "Authorization" => "Bearer #{@access_token}" },
      timeout: 5,
    )
    unless response.success?
      Rails.logger.error("TiktokProfileFetcher HTTP #{response.code}")
      return
    end

    body = response.parsed_response
    return unless body.is_a?(Hash)

    error_code = body.dig("error", "code")
    if error_code.present? && error_code != "ok"
      Rails.logger.error("TiktokProfileFetcher API #{error_code}")
      return
    end

    user = body.dig("data", "user")
    return unless user.is_a?(Hash)
    return if user["open_id"].blank?

    user
  rescue HTTParty::Error, SocketError, Timeout::Error, JSON::ParserError, Errno::ECONNRESET, OpenSSL::SSL::SSLError => e
    Rails.logger.error("TiktokProfileFetcher failed: #{e.class}")
    nil
  end
end
