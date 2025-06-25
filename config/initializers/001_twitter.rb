# frozen_string_literal: true


TWITTER_APP_ID = GlobalConfig.get("TWITTER_APP_ID")
TWITTER_APP_SECRET = GlobalConfig.get("TWITTER_APP_SECRET")

$twitter = Twitter::REST::Client.new do |config|
  config.consumer_key        = TWITTER_APP_ID
  config.consumer_secret     = TWITTER_APP_SECRET
end
