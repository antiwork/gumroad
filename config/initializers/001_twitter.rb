# frozen_string_literal: true

# We're using an ancient omniauth-twitter gem that relies on this removed behavior
# See https://github.com/rack/rack/pull/2183/files#diff-7ce97931f18a63a4d028696a6f4ba81991644dbc2d70eaa664285264e9a5cd64L612
# TODO (sharang): Change the gem or approach to twitter signup/connection and remove this patch
module Rack
  class Request
    # shortcut for <tt>request.params[key]</tt>
    def [](key)
      warn("Request#[] is deprecated and will be removed in a future version of Rack. Please use request.params[] instead", uplevel: 1)

      params[key.to_s]
    end
  end
end

TWITTER_APP_ID = GlobalConfig.get("TWITTER_APP_ID")
TWITTER_APP_SECRET = GlobalConfig.get("TWITTER_APP_SECRET")

$twitter = Twitter::REST::Client.new do |config|
  config.consumer_key        = TWITTER_APP_ID
  config.consumer_secret     = TWITTER_APP_SECRET
end
