# frozen_string_literal: true

# Pulls the authorized user's YouTube channel + latest upload from the Data API.
# Google's login OAuth payload has no subscriber/video counts; this is the
# verification metadata SocialConnectVerification stores.
class YoutubeChannelFetcher
  CHANNELS_URL = "https://www.googleapis.com/youtube/v3/channels"
  PLAYLIST_ITEMS_URL = "https://www.googleapis.com/youtube/v3/playlistItems"

  def initialize(access_token)
    @access_token = access_token
  end

  def fetch
    return if @access_token.blank?

    channel = get_json(CHANNELS_URL, part: "snippet,statistics,contentDetails", mine: true)
    item = channel&.dig("items", 0)
    return if item.blank? || item["id"].blank?

    {
      "id" => item["id"],
      "handle" => handle_from(item),
      "published_at" => item.dig("snippet", "publishedAt"),
      "subscriber_count" => item.dig("statistics", "subscriberCount"),
      "video_count" => item.dig("statistics", "videoCount"),
      "last_posted_at" => last_upload_at(item),
    }
  rescue HTTParty::Error, SocketError, Timeout::Error, JSON::ParserError, Errno::ECONNRESET, OpenSSL::SSL::SSLError => e
    Rails.logger.error("YoutubeChannelFetcher failed: #{e.class}")
    nil
  end

  private
    def handle_from(item)
      custom = item.dig("snippet", "customUrl")
      return if custom.blank?

      custom.delete_prefix("@").delete_prefix("/")
    end

    def last_upload_at(item)
      uploads = item.dig("contentDetails", "relatedPlaylists", "uploads")
      return if uploads.blank?

      playlist = get_json(PLAYLIST_ITEMS_URL, part: "snippet", playlistId: uploads, maxResults: 1)
      published = playlist&.dig("items", 0, "snippet", "publishedAt")
      Time.iso8601(published) if published.present?
    rescue ArgumentError
      nil
    end

    def get_json(url, **query)
      response = HTTParty.get(
        url,
        query:,
        headers: { "Authorization" => "Bearer #{@access_token}" },
        timeout: 5,
      )
      unless response.success?
        Rails.logger.error("YoutubeChannelFetcher HTTP #{response.code}")
        return
      end

      response.parsed_response
    end
end
