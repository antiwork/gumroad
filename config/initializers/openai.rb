# frozen_string_literal: true

request_timeout_in_seconds = 3

OpenAI.configure do |config|
  config.access_token = GlobalConfig.get("OPENAI_ACCESS_TOKEN")
  config.request_timeout = request_timeout_in_seconds
end
