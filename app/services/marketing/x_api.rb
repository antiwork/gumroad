# frozen_string_literal: true

require "simple_oauth"

# v1.1 statuses/update is retired (404), so tweets go through POST /2/tweets signed
# with the seller's OAuth 1.0a user token under the Gumroad X app.
class Marketing::XApi
  TWEETS_URL = "https://api.twitter.com/2/tweets"

  Response = Struct.new(:status, :body, keyword_init: true) do
    def created? = status == 201
    def tweet_id = body.dig("data", "id")
    # A 401 always means this token cannot authenticate. A 403 means it cannot write for
    # OAuth 1.0a user context — read-only app tier or scopes as minted — unless X names a
    # content refusal, since it returns 403 for duplicate copy and over-length text too.
    def write_forbidden? = status == 401 || (status == 403 && !content_refused?)
    # Any other 4xx is a refusal: nothing was posted, and reconnecting would not help.
    def rejected? = status.to_i.between?(400, 499) && !write_forbidden?

    private
      # Wording X uses when it refuses the content itself rather than the token's scope.
      CONTENT_REFUSALS = [/duplicate/i, /too long/i, /client-not-enrolled/i].freeze

      def content_refused? = CONTENT_REFUSALS.any? { |pattern| body["detail"].to_s.match?(pattern) }
  end

  # A dropped or timed-out connection raises instead of returning a response, and X may
  # have accepted the tweet before it died, so it is reported with a nil status: the
  # caller treats every non-201 as an unknown result rather than retrying it.
  NETWORK_ERRORS = [
    Timeout::Error, EOFError, SocketError, SystemCallError, OpenSSL::SSL::SSLError,
  ].freeze

  def self.post_tweet(user:, text:)
    header = SimpleOAuth::Header.new(:post, TWEETS_URL, {},
                                     consumer_key: TWITTER_APP_ID, consumer_secret: TWITTER_APP_SECRET,
                                     token: user.twitter_oauth_token, token_secret: user.twitter_oauth_secret)
    response = HTTParty.post(TWEETS_URL, body: { text: }.to_json,
                                         headers: { "Authorization" => header.to_s, "Content-Type" => "application/json" },
                                         timeout: 15)
    Response.new(status: response.code, body: response.parsed_response.is_a?(Hash) ? response.parsed_response : {})
  rescue *NETWORK_ERRORS
    Response.new(status: nil, body: {})
  end
end
