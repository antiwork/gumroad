# frozen_string_literal: true

JsRoutes.setup do |config|
  config.url_links = true
  # Don't determine protocol from window.location (prerendering)
  config.default_url_options = { protocol: PROTOCOL, host: DOMAIN }
  config.exclude = [/^api_/]
  # Output to utils folder where the codebase expects it
  config.file = Rails.root.join("app/javascript/utils/routes.js")
end
