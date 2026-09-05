# frozen_string_literal: true

class InstagramProfileFetcher
  GRAPH_URL = "https://graph.instagram.com"

  def initialize(access_token)
    @access_token = access_token
  end

  def fetch
    return if @access_token.blank?

    response = get_json("#{GRAPH_URL}/#{INSTAGRAM_API_VERSION}/me", fields: "user_id,username,followers_count,media_count")
    profile = response&.dig("data", 0)
    uid = profile&.fetch("user_id", nil)
    return if uid.blank?

    profile.merge("last_posted_at" => last_posted_at(uid))
  rescue HTTParty::Error, SocketError, Timeout::Error, JSON::ParserError, Errno::ECONNRESET, OpenSSL::SSL::SSLError => e
    Rails.logger.error("InstagramProfileFetcher failed: #{e.class}")
    nil
  end

  private
    def last_posted_at(user_id)
      media = get_json("#{GRAPH_URL}/#{INSTAGRAM_API_VERSION}/#{user_id}/media", fields: "timestamp", limit: 1)
      media&.dig("data", 0, "timestamp")
    end

    def get_json(url, **query)
      response = HTTParty.get(
        url,
        query:,
        headers: { "Authorization" => "Bearer #{@access_token}" },
        timeout: 5,
      )
      unless response.success?
        Rails.logger.error("InstagramProfileFetcher HTTP #{response.code}")
        return
      end

      response.parsed_response
    end
end
