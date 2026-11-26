# frozen_string_literal: true

# Publishing to a seller's Instagram professional account with the token they granted
# through Instagram Login. A post is two calls: Meta downloads the image into a
# container, and only publishing that container makes anything public.
class Marketing::InstagramApi
  GRAPH_URL = "https://graph.instagram.com"
  # Meta's OAuthException code for a token that is expired, revoked or malformed.
  INVALID_TOKEN_CODE = 190

  Response = Struct.new(:status, :body, keyword_init: true) do
    def ok? = status == 200
    def id = body["id"]
    def access_token = body["access_token"]
    def expires_in = body["expires_in"].to_i
    def status_code = body["status_code"]
    def permalink = body["permalink"]
    # The token cannot act for this account: reconnecting is what fixes it.
    def unauthorized? = [401, 403].include?(status) || body.dig("error", "code") == INVALID_TOKEN_CODE
    # Any other 4xx is a refusal of the request itself, which a reconnect would not change.
    def rejected? = status.to_i.between?(400, 499) && !unauthorized?
  end

  NETWORK_ERRORS = [
    Timeout::Error, EOFError, SocketError, SystemCallError, OpenSSL::SSL::SSLError, HTTParty::Error, JSON::ParserError,
  ].freeze

  def self.exchange_for_long_lived_token(short_lived_token)
    get("#{GRAPH_URL}/access_token", query: {
          grant_type: "ig_exchange_token", client_secret: INSTAGRAM_APP_SECRET, access_token: short_lived_token,
        })
  end

  def self.refresh_token(token)
    get("#{GRAPH_URL}/refresh_access_token", query: { grant_type: "ig_refresh_token", access_token: token })
  end

  def initialize(identity)
    @identity = identity
  end

  def create_image_container(image_url:, caption:)
    post("#{@identity.instagram_user_id}/media", image_url:, caption:)
  end

  def container_status(container_id)
    self.class.get(versioned(container_id), query: { fields: "status_code" }, token: @identity.access_token)
  end

  def publish(container_id)
    post("#{@identity.instagram_user_id}/media_publish", creation_id: container_id)
  end

  def permalink(media_id)
    self.class.get(versioned(media_id), query: { fields: "permalink" }, token: @identity.access_token)
  end

  # A dropped connection is reported with a nil status, as Marketing::XApi does, so the
  # caller decides what an unanswered request means for the step it was on.
  def self.get(url, query:, token: nil)
    headers = token ? { "Authorization" => "Bearer #{token}" } : {}
    wrap(HTTParty.get(url, query:, headers:, timeout: 15))
  rescue *NETWORK_ERRORS
    Response.new(status: nil, body: {})
  end

  def self.wrap(response)
    Response.new(status: response.code, body: response.parsed_response.is_a?(Hash) ? response.parsed_response : {})
  end

  private
    def versioned(path) = "#{GRAPH_URL}/#{INSTAGRAM_API_VERSION}/#{path}"

    def post(path, **body)
      self.class.wrap(HTTParty.post(versioned(path), body: body.to_json, timeout: 15, headers: {
                                      "Authorization" => "Bearer #{@identity.access_token}", "Content-Type" => "application/json",
                                    }))
    rescue *NETWORK_ERRORS
      Response.new(status: nil, body: {})
    end
end
