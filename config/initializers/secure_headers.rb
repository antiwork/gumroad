# frozen_string_literal: true

cookie_config = if PROTOCOL == "https"
  {
    httponly: true,
    secure: true,
    samesite: { none: true }
  }
else
  {
    httponly: true,
    secure: SecureHeaders::OPT_OUT,
    samesite: { lax: true }
  }
end

SecureHeaders::Configuration.default do |config|
  config.cookies = cookie_config

  config.hsts = SecureHeaders::OPT_OUT
  config.x_frame_options = SecureHeaders::OPT_OUT
  config.x_content_type_options = "nosniff"
  config.x_xss_protection = "1; mode=block"

  config.csp = {
    default_src: ["https", "'self'"],

    frame_src: ["*", "data:", "blob:"],
    worker_src: ["*", "data:", "blob:"],
    object_src: ["*", "data:", "blob:"],
    child_src: ["*", "data:", "blob:"],
    img_src: ["*", "data:", "blob:"],
    font_src: ["*", "data:", "blob:"],
    media_src: ["*", "data:", "blob:"],

    connect_src: [
      "'self'",

      "blob:",

      # dropbox
      "www.dropbox.com",
      "api.dropboxapi.com",

      # direct file uploads to aws s3
      "s3.amazonaws.com/#{S3_BUCKET}",
      "s3.amazonaws.com/#{S3_BUCKET}/",

      # direct file uploads to aws s3
      "#{PUBLIC_STORAGE_S3_BUCKET}.s3.amazonaws.com",
      "#{PUBLIC_STORAGE_S3_BUCKET}.s3.amazonaws.com/",

      # direct file uploads to aws s3
      "s3.amazonaws.com/#{PUBLIC_STORAGE_S3_BUCKET}",
      "s3.amazonaws.com/#{PUBLIC_STORAGE_S3_BUCKET}/",

      # recaptcha
      "www.google.com",
      "www.gstatic.com",

      # facebook
      "*.facebook.com",
      "*.facebook.net",

      # google analytics
      "*.google-analytics.com",
      "*.g.doubleclick.net",
      "*.googletagmanager.com",
      "analytics.google.com",
      "*.analytics.google.com",

      # cloudfront
      FILE_DOWNLOAD_DISTRIBUTION_URL,
      HLS_DISTRIBUTION_URL,

      # paypal
      "*.braintreegateway.com",
      "www.paypalobjects.com",
      "*.paypal.com",
      "*.braintree-api.com",

      # oembeds - rich text editor
      "iframe.ly",

      # helper widget
      "help.gumroad.com",
    ],
    script_src: [
      "'self'",

      "'unsafe-eval'",

      # Cloudflare - Rocket Loader
      "ajax.cloudflare.com",

      # Cloudflare - Browser Insights
      "static.cloudflareinsights.com",

      # stripe frontend tokenization
      "js.stripe.com",
      "api.stripe.com",
      "connect-js.stripe.com",

      # braintree
      "*.braintreegateway.com",
      "*.braintree-api.com",

      # paypal
      "www.paypalobjects.com",
      "*.paypal.com",

      # google analytics
      "*.google-analytics.com",
      "*.googletagmanager.com",

      # google optimize
      "optimize.google.com",

      # google ads
      "www.googleadservices.com",

      # recaptcha
      "www.google.com",
      "www.gstatic.com",

      # facebook login and other uses
      "*.facebook.net",
      "*.facebook.com",

      # send to dropbox
      "www.dropbox.com",

      # oembeds - youtube
      "s.ytimg.com",
      "www.google.com",

      # oembeds - rich text editor
      "cdn.iframe.ly",
      "platform.twitter.com",

      # jw player
      "cdn.jwplayer.com",
      "*.jwpcdn.com",

      # mailchimp
      "gumroad.us3.list-manage.com",

      # twitter
      "analytics.twitter.com",

      # helper widget
      "help.gumroad.com",

      # lottie - homepage
      "unpkg.com/@lottiefiles/lottie-player@latest/"
    ],
    style_src: [
      "'self'",

      # custom css is in inline tags
      "'unsafe-inline'",

      # oembeds - youtube
      "s.ytimg.com",

      # google optimize
      "optimize.google.com",

      # google fonts
      "fonts.googleapis.com"
    ]
  }

  config.csp[:connect_src] << "#{DOMAIN}"
  config.csp[:script_src] << "#{DOMAIN}"

  # Required by AnyCable
  config.csp[:connect_src] << "wss://#{ANYCABLE_HOST}"

  # Required for realtime events in Helper widget
  config.csp[:connect_src] << "wss://#{ENV["HELPER_SUPABASE_DOMAIN"]}" if ENV["HELPER_SUPABASE_DOMAIN"].present?

  if Rails.application.config.asset_host.present?
    config.csp[:connect_src] << Rails.application.config.asset_host
    config.csp[:script_src] << Rails.application.config.asset_host
    config.csp[:style_src] << Rails.application.config.asset_host
  end

  if Rails.env.test?
    config.csp[:default_src] = ["'self'"]
    config.csp[:style_src] << "blob:" # Required by Shakapacker to serve CSS
    config.csp[:script_src] << "test-custom-domain.gumroad.com:#{URI("#{PROTOCOL}://#{DOMAIN}").port}" # To allow loading widget scripts from the custom domain
    config.csp[:script_src] << ROOT_DOMAIN # Required to load gumroad.js for overlay/embed.
    config.csp[:connect_src] << "ws://#{ANYCABLE_HOST}:8080" # Required by AnyCable
    config.csp[:connect_src] << "wss://#{ANYCABLE_HOST}:8080" # Required by AnyCable
    # Allow S3-compatible services like MinIO
    config.csp[:connect_src] << "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}"
    config.csp[:connect_src] << "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/"
  elsif Rails.env.development?
    config.csp[:default_src] = ["'self'"]
    config.csp[:style_src] << "blob:" # Required by Shakapacker to serve CSS
    config.csp[:script_src] << "gumroad.dev:3035" # Required by webpack-dev-server
    config.csp[:script_src] << "'unsafe-inline'" # Allow react-on-rails to inject server-rendering logs into the browser
    config.csp[:connect_src] << "gumroad.dev:3035" # Required by webpack-dev-server
    config.csp[:connect_src] << "wss://gumroad.dev:3035" # Required by webpack-dev-server
    config.csp[:connect_src] << "wss://#{ANYCABLE_HOST}:8081" # Required by AnyCable
    config.csp[:connect_src] << "helperai.dev" # Required by Helper widget
    config.csp[:connect_src] << "wss://supabase.helperai.dev" # Required by Helper widget
    config.csp[:connect_src] << "http:"
    config.csp[:script_src] << "http:" # Required by Helper widget
    config.csp[:script_src] << "helperai.dev" # Required by Helper widget
  end
end
